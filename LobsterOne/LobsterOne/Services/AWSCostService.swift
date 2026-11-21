import Combine
import Foundation

/// Who the AWS keys belong to, from the free STS check.
nonisolated struct AWSIdentity: Equatable, Sendable {
    /// How much of the bill a login can read. Only an organization's management account
    /// sees every account; any other sees just its own.
    enum Scope: Equatable, Sendable { case allAccounts, oneAccount, unknown }

    let account: String
    let arn: String
    var scope: Scope = .unknown
}

/// The AWS logins the person connected, and the cost monitor that reads through them. One
/// login that sees every account is enough; without one, several can be connected and their
/// accounts are shown together and totalled. The choices are saved in UserDefaults as
/// profile names or a marker that keys are in the Keychain; no secret is ever written there.
@MainActor
final class AWSCostService: ObservableObject {
    static let connectionsKey = "awsConnections"
    /// Where a single login was saved before several could be connected.
    static let legacyConnectionKey = "awsConnection"
    static let menuBarKey = "awsCostInMenuBar"
    /// The Refresh buttons wait this long between requests, so pressing them repeatedly can't
    /// run up Cost Explorer charges.
    static let manualRefreshInterval: TimeInterval = 300

    /// Connected logins, in the order they were added.
    @Published private(set) var connections: [AWSConnection]
    /// Which account each connected login is, once a free STS check has said.
    @Published private(set) var identities: [AWSConnection: AWSIdentity] = [:]
    /// The accounts each login returned costs for at the last refresh.
    @Published private(set) var coverage: [AWSConnection: Set<String>] = [:]
    /// Logins that couldn't be read at the last refresh, while others could.
    @Published private(set) var fetchProblems: [AWSConnection: CostError] = [:]
    /// Whether each profile in ~/.aws can sign in right now, by profile name. Filled by
    /// `checkProfiles`, so Settings can say which logins work before one is chosen.
    @Published private(set) var checks: [String: LoginCheck] = [:]
    @Published var showsTotalInMenuBar: Bool {
        didSet { defaults.set(showsTotalInMenuBar, forKey: Self.menuBarKey) }
    }

    let monitor: CostMonitor
    private let provider: AWSCredentialProvider
    private let defaults: UserDefaults
    private let home: URL
    private let secrets: any AWSSecretStoring
    private let transport: AWSAPI.Transport
    private let now: () -> Date
    private let plan: FetchPlan
    private var profilesCheckedAt: Date?
    private var refreshWanted = false
    private var refreshLoop: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         secrets: any AWSSecretStoring = AWSKeychainSecrets(),
         runner: any AWSProcessRunning = AWSProcessRunner(),
         transport: @escaping AWSAPI.Transport = AWSAPI.urlSession(),
         cacheURL: URL? = CostMonitor.defaultCacheURL,
         alertStore: CostAlertStore = CostAlertStore(),
         notifier: AlertNotifying? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.home = home
        self.secrets = secrets
        self.transport = transport
        self.now = now
        let provider = AWSCredentialProvider(home: home, runner: runner, secrets: secrets)
        self.provider = provider
        let plan = FetchPlan()
        self.plan = plan
        self.connections = Self.loadConnections(defaults)
        // On unless switched off: the total is the figure people connect AWS to see.
        self.showsTotalInMenuBar = defaults.object(forKey: Self.menuBarKey) as? Bool ?? true
        self.profileAccountNames = AWSProfiles.accountNamesFromDisk(home: home)
        // The monitor reads the saved choices each time, so it never sees a stale list.
        self.monitor = CostMonitor(
            isConnected: { !Self.loadConnections(defaults).isEmpty },
            makeFetcher: {
                let connections = Self.loadConnections(defaults)
                guard !connections.isEmpty else { throw CostError.notConnected }
                let reusable = plan.takeReusable()
                return CombinedCostFetcher(
                    parts: connections.map { connection in
                        .init(key: connection,
                              fetcher: AWSCostFetcher(api: AWSAPI(provider: provider, connection: connection, transport: transport)),
                              reuse: reusable[connection])
                    },
                    report: { read, problems in await plan.deliver(read, problems) })
            },
            cacheURL: cacheURL, alertStore: alertStore, notifier: notifier ?? CostAlertNotifier(), now: now)
        monitor.localNames = { [weak self] in self?.localAccountNames ?? [:] }
        plan.onResults = { [weak self] read, problems in
            guard let self else { return }
            self.coverage = read.mapValues { Set($0.thisMonth.keys).union($0.lastMonth.keys) }
                .filter { self.connections.contains($0.key) }
            self.fetchProblems = problems.filter { self.connections.contains($0.key) }
        }
    }

    var isConnected: Bool { !connections.isEmpty }

    func isConnected(_ connection: AWSConnection) -> Bool { connections.contains(connection) }

    /// Adds a login and reads its costs. Logins already connected aren't asked again, so
    /// adding several in a row costs one request each, not one per login each time.
    func connect(_ connection: AWSConnection) {
        guard !connections.contains(connection) else { return }
        connections.append(connection)
        save()
        let provider = provider
        Task {
            await provider.invalidate(connection)
            await identify(connection)
        }
        refreshSoon()
    }

    /// Saves pasted keys in the Keychain, then connects with them.
    func connectWithAccessKeys(id: String, secret: String) throws {
        guard let keys = Self.cleanKeys(id: id, secret: secret) else { throw AWSKeysError.empty }
        try secrets.saveAccessKeys(id: keys.id, secret: keys.secret)
        // New keys may belong to another account, even when keys were connected before.
        forget(.accessKeys)
        connections.removeAll { $0 == .accessKeys }
        connect(.accessKeys)
    }

    /// Removes one login. Its accounts leave the list and the total; the others stay, read
    /// from what was fetched moments ago where that's still fresh.
    func disconnect(_ connection: AWSConnection) {
        guard connections.contains(connection) else { return }
        connections.removeAll { $0 == connection }
        if connection == .accessKeys { try? secrets.deleteAccessKeys() }
        forget(connection)
        save()
        let provider = provider
        Task { await provider.invalidate(connection) }
        if connections.isEmpty {
            monitor.reset()
        } else {
            refreshSoon()
        }
    }

    /// Forgets every login: the Keychain keys, the saved choices and every cached figure.
    /// Alert amounts stay, as `CostMonitor.reset` explains.
    func disconnectAll() {
        try? secrets.deleteAccessKeys()
        connections = []
        identities = [:]
        coverage = [:]
        fetchProblems = [:]
        plan.clear()
        save()
        monitor.reset()
        let provider = provider
        Task { await provider.invalidate() }
    }

    private func forget(_ connection: AWSConnection) {
        identities[connection] = nil
        coverage[connection] = nil
        fetchProblems[connection] = nil
        plan.drop(connection)
    }

    private func save() {
        defaults.removeObject(forKey: Self.legacyConnectionKey)
        if connections.isEmpty {
            defaults.removeObject(forKey: Self.connectionsKey)
        } else if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: Self.connectionsKey)
        }
    }

    /// Refreshes after the list of logins changed. Readings taken within the hour are kept,
    /// so only a newly added login is paid for. Changes made while a refresh is running are
    /// picked up by one more refresh after it, never dropped.
    private func refreshSoon() {
        refreshWanted = true
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while let self, self.refreshWanted {
                while self.monitor.isRefreshing { try? await Task.sleep(for: .milliseconds(50)) }
                self.refreshWanted = false
                self.plan.reuseOnce(Set(self.connections))
                await self.monitor.refreshNow()
            }
            self?.refreshLoop = nil
        }
    }

    /// A login to try before saving it.
    enum Draft: Equatable {
        case profile(String)
        case accessKeys(id: String, secret: String)
    }

    /// Asks STS who the keys belong to. Free, and needs no permissions, so it says whether the
    /// login works at all; it can't say whether billing data is readable.
    func testConnection(_ draft: Draft) async -> Result<AWSIdentity, CostError> {
        switch draft {
        case .profile(let name):
            return await whoIs(AWSAPI(provider: provider, connection: .profile(name: name), transport: transport))
        case .accessKeys(let id, let secret):
            guard let keys = Self.cleanKeys(id: id, secret: secret) else {
                return .failure(.other(AWSKeysError.empty.message))
            }
            let credentials = AWSCredentials(accessKeyId: keys.id, secretAccessKey: keys.secret)
            return await whoIs(AWSAPI(credentials: { credentials }, transport: transport))
        }
    }

    /// The same free check for a connected login, remembered so its row can name the account.
    @discardableResult
    func identify(_ connection: AWSConnection) async -> Result<AWSIdentity, CostError> {
        let result = await whoIs(AWSAPI(provider: provider, connection: connection, transport: transport))
        if case .success(let who) = result, connections.contains(connection) { identities[connection] = who }
        return result
    }

    private func whoIs(_ api: AWSAPI) async -> Result<AWSIdentity, CostError> {
        do {
            let who = try await api.callerIdentity()
            return .success(AWSIdentity(account: who.account, arn: who.arn,
                                        scope: await Self.scope(of: who.account, api: api)))
        } catch {
            return .failure(AWSCostFetcher.explain(error))
        }
    }

    /// Whether this account is its organization's management account. Free to ask; when AWS
    /// won't say (the login may not be allowed to), the answer is `.unknown`, never a guess.
    private static func scope(of account: String, api: AWSAPI) async -> AWSIdentity.Scope {
        do {
            // No organization at all: this account is all there is.
            guard let management = try await api.managementAccountId() else { return .allAccounts }
            return management == account ? .allAccounts : .oneAccount
        } catch {
            return .unknown
        }
    }

    /// Asks once, at launch, which account each saved login is and how much it can see.
    func refreshIdentities() async {
        for connection in connections where identities[connection] == nil {
            await identify(connection)
        }
    }

    // MARK: - What the logins cover

    /// What to call a login in a sentence.
    static func label(_ connection: AWSConnection) -> String {
        switch connection {
        case .profile(let name): name
        case .accessKeys: "the pasted access keys"
        }
    }

    /// Another connected login that already returns every account this one does, so this
    /// one adds a request without adding anything to the list. Nil when it earns its place.
    func coveredBy(_ connection: AWSConnection) -> AWSConnection? {
        guard let mine = coverage[connection], !mine.isEmpty else { return nil }
        return connections.first { other in
            guard other != connection, let theirs = coverage[other] else { return false }
            // Two logins seeing exactly the same accounts: only the later one is spare.
            if theirs == mine {
                return (connections.firstIndex(of: other) ?? 0) < (connections.firstIndex(of: connection) ?? 0)
            }
            return theirs.isSuperset(of: mine)
        }
    }

    /// One line for the popover when the list may not be the whole bill: a login that
    /// couldn't be read, or a lone login that sees a single account. Nil when there's
    /// nothing to say.
    var pageNote: String? {
        let failed = connections.filter { fetchProblems[$0] != nil }
        if let first = failed.first {
            if failed.count > 1 { return "\(failed.count) logins couldn't be read, so their accounts are missing from the total." }
            let name = Self.label(first)
            return "\(name.prefix(1).uppercased() + name.dropFirst()) couldn't be read, so its accounts are missing from the total."
        }
        guard connections.count == 1, let only = connections.first, identities[only]?.scope == .oneAccount else { return nil }
        let wider = checks.sorted { $0.key < $1.key }.first { entry in
            if case .ready(let who) = entry.value { return who.scope == .allAccounts }
            return false
        }?.key
        if let wider { return "This login sees one AWS account. Add \(wider) to see them all." }
        return "This login sees one AWS account. Add your other logins to see them together."
    }

    // MARK: - Account names

    /// Account id → profile name from ~/.aws/config, re-read whenever the profiles are checked.
    private var profileAccountNames: [String: String] = [:]

    /// Names for accounts AWS Organizations didn't name: the profile that points at the
    /// account, from its settings or from a check that signed in to it.
    var localAccountNames: [String: String] {
        var names = profileAccountNames
        for (profile, check) in checks.sorted(by: { $0.key < $1.key }) {
            if case .ready(let who) = check, names[who.account] == nil { names[who.account] = profile }
        }
        for connection in connections {
            if case .profile(let name) = connection, let account = identities[connection]?.account,
               names[account] == nil {
                names[account] = name
            }
        }
        return names
    }

    // MARK: - Checking logins

    /// What a free STS check said about one profile.
    enum LoginCheck: Equatable {
        case checking
        case ready(AWSIdentity)
        case failed(CostError)
    }

    /// Opening Settings again within this long reuses the last answers.
    static let profileCheckInterval: TimeInterval = 600
    /// SSO, role and process profiles each start the aws CLI; a few at a time is plenty.
    private static let checksAtOnce = 4

    /// Asks STS about every profile, so each row can show whether it would work. Free: STS
    /// bills nothing, and an expired sign-in is only reported, never renewed from here.
    func checkProfiles(force: Bool = false) async {
        let current = now()
        if !force, let last = profilesCheckedAt, current.timeIntervalSince(last) < Self.profileCheckInterval { return }
        profilesCheckedAt = current
        profileAccountNames = AWSProfiles.accountNamesFromDisk(home: home)
        let names = profiles.map(\.name)
        checks = checks.filter { names.contains($0.key) }
        for name in names where checks[name] == nil { checks[name] = .checking }
        var rest = names[...]
        while !rest.isEmpty {
            let batch = rest.prefix(Self.checksAtOnce)
            rest = rest.dropFirst(batch.count)
            await withTaskGroup(of: Void.self) { group in
                for name in batch { group.addTask { await self.check(name, quietly: true) } }
            }
        }
    }

    /// Checks one profile, for its row's "Check again". `quietly` keeps the last answer on
    /// screen while a routine re-check runs.
    func check(_ name: String, quietly: Bool = false) async {
        if !quietly || checks[name] == nil { checks[name] = .checking }
        switch await testConnection(.profile(name)) {
        case .success(let who):
            checks[name] = .ready(who)
            if connections.contains(.profile(name: name)) { identities[.profile(name: name)] = who }
        case .failure(let error):
            checks[name] = .failed(error)
        }
    }

    // MARK: - Profiles

    struct Profile: Identifiable, Equatable {
        let name: String
        let kind: AWSProfiles.ProfileKind
        var id: String { name }

        var kindLabel: String {
            switch kind {
            case .staticKeys: "Access keys"
            case .sso: "SSO"
            case .assumeRole: "Role"
            case .needsMFA: "MFA"
            case .process: "Process"
            case .empty: "No login"
            }
        }

        /// Every kind but plain keys gets its keys from the installed aws command.
        var usesCLI: Bool { kind != .staticKeys && kind != .empty }
    }

    /// Profiles in ~/.aws that could log in. Ones with no login settings, or with names the
    /// CLI won't be handed, are left out.
    var profiles: [Profile] {
        AWSProfiles.profileNamesFromDisk(home: home)
            .filter(AWSProfiles.isValidName)
            .map { Profile(name: $0, kind: AWSProfiles.profileKindFromDisk($0, home: home)) }
            .filter { $0.kind != .empty }
    }

    // MARK: - Helpers

    private static func loadConnections(_ defaults: UserDefaults) -> [AWSConnection] {
        if let data = defaults.data(forKey: connectionsKey),
           let saved = try? JSONDecoder().decode([AWSConnection].self, from: data) {
            return saved
        }
        // Saved by a build that knew one login at a time.
        if let data = defaults.data(forKey: legacyConnectionKey),
           let single = try? JSONDecoder().decode(AWSConnection.self, from: data) {
            return [single]
        }
        return []
    }

    /// Trimmed keys, or nil when either is empty. Pasting from a console often brings a space.
    nonisolated static func cleanKeys(id: String, secret: String) -> (id: String, secret: String)? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }
}

nonisolated enum AWSKeysError: Error, Equatable {
    case empty

    var message: String { "Paste both the access key ID and the secret access key." }
}

/// What passes between the service and the fetchers it hands the monitor: the last reading
/// per login, which of them the next fetch may reuse, and where results are reported. The
/// fetchers run off the main actor, hence the lock.
private final class FetchPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [AWSConnection: CostSnapshot] = [:]
    private var reusable: Set<AWSConnection> = []
    @MainActor var onResults: (([AWSConnection: CostSnapshot], [AWSConnection: CostError]) -> Void)?

    /// Lets the next fetch, and only that one, reuse fresh readings of these logins.
    func reuseOnce(_ connections: Set<AWSConnection>) {
        lock.withLock { reusable = connections }
    }

    func takeReusable() -> [AWSConnection: CostSnapshot] {
        lock.withLock {
            defer { reusable = [] }
            return readings.filter { reusable.contains($0.key) }
        }
    }

    func drop(_ connection: AWSConnection) {
        lock.withLock { readings[connection] = nil }
    }

    func clear() {
        lock.withLock { readings = [:]; reusable = [] }
    }

    func deliver(_ read: [AWSConnection: CostSnapshot], _ problems: [AWSConnection: CostError]) async {
        lock.withLock { readings.merge(read) { _, new in new } }
        await MainActor.run { onResults?(read, problems) }
    }
}
