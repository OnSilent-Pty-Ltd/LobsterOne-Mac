import Testing
import Foundation
@testable import LobsterOne

/// Answers each request by the AWS service it's for, and counts Cost Explorer calls (the paid ones).
private final class RoutingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    var costStatus = 200
    var costBody = """
    {"ResultsByTime":[
      {"Estimated":false,"TimePeriod":{"Start":"2026-10-01","End":"2026-11-01"},
       "Groups":[{"Keys":["111111111111"],"Metrics":{"UnblendedCost":{"Amount":"40","Unit":"USD"}}}]},
      {"Estimated":true,"TimePeriod":{"Start":"2026-11-01","End":"2026-12-01"},
       "Groups":[{"Keys":["111111111111"],"Metrics":{"UnblendedCost":{"Amount":"12.5","Unit":"USD"}}},
                 {"Keys":["222222222222"],"Metrics":{"UnblendedCost":{"Amount":"3","Unit":"USD"}}}]}]}
    """
    var orgStatus = 200
    var orgBody = #"{"Accounts":[{"Id":"111111111111","Name":"Production"}]}"#
    var costHeaders: [String: String] = [:]
    var stsFailure: URLError?
    /// What DescribeOrganization answers; nil stands for a login that isn't allowed to ask.
    var managementAccount: String?
    /// Per access key id: what Cost Explorer answers, and which account STS says it is.
    var costByKey: [String: (status: Int, body: String)] = [:]
    var accountByKey: [String: String] = [:]

    static func costs(_ thisMonth: [String: Double]) -> String {
        let groups = thisMonth.sorted { $0.key < $1.key }
            .map { #"{"Keys":["\#($0.key)"],"Metrics":{"UnblendedCost":{"Amount":"\#($0.value)","Unit":"USD"}}}"# }
            .joined(separator: ",")
        return #"{"ResultsByTime":[{"Estimated":true,"TimePeriod":{"Start":"2026-11-01","End":"2026-12-01"},"Groups":[\#(groups)]}]}"#
    }

    private var _costBody: Data?
    var hosts: [String] { lock.withLock { _hosts } }
    var lastCostRequestBody: [String: Any] {
        lock.withLock { _costBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    var costCalls: Int { hosts.filter { $0.hasPrefix("ce.") }.count }

    var transport: AWSAPI.Transport { { request in try self.send(request) } }

    private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        lock.withLock {
            _hosts.append(host)
            if host.hasPrefix("ce.") { _costBody = request.httpBody }
        }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = auth.components(separatedBy: "Credential=").dropFirst().first?
            .components(separatedBy: "/").first ?? ""
        let (status, body, headers): (Int, String, [String: String])
        if host.hasPrefix("ce."), let own = costByKey[key] {
            (status, body, headers) = (own.status, own.body, [:])
        } else if host.hasPrefix("ce.") {
            (status, body, headers) = (costStatus, costBody, costHeaders)
        } else if host.hasPrefix("organizations."),
                  request.value(forHTTPHeaderField: "X-Amz-Target")?.hasSuffix("DescribeOrganization") == true {
            if let managementAccount {
                (status, body, headers) = (200, #"{"Organization":{"Id":"o-x","MasterAccountId":"\#(managementAccount)"}}"#, [:])
            } else {
                (status, body, headers) = (400, #"{"__type":"AccessDeniedException","message":"no"}"#, [:])
            }
        } else if host.hasPrefix("organizations.") {
            (status, body, headers) = (orgStatus, orgBody, [:])
        } else {
            if let stsFailure { throw stsFailure }
            let account = accountByKey[key] ?? "111111111111"
            (status, body, headers) = (200, #"{"GetCallerIdentityResponse":{"GetCallerIdentityResult":{"Account":"\#(account)","Arn":"arn:aws:iam::\#(account):user/costs"}}}"#, [:])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

private final class MemorySecrets: AWSSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: (id: String, secret: String)?
    func readAccessKeys() -> (id: String, secret: String)? { lock.withLock { keys } }
    func saveAccessKeys(id: String, secret: String) throws { lock.withLock { keys = (id, secret) } }
    func deleteAccessKeys() throws { lock.withLock { keys = nil } }
}

@MainActor
private final class SilentNotifier: AlertNotifying {
    let isEnabled = true
    func requestPermission() {}
    func notify(id: String, title: String, body: String) {}
}

private let now = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!
private let staticKeys = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret")

private func fetcher(_ fake: RoutingTransport) -> AWSCostFetcher {
    AWSCostFetcher(api: AWSAPI(credentials: { staticKeys }, transport: fake.transport, now: { now }))
}

// MARK: - Fetcher

@Test func fetcherBuildsSnapshotWithNames() async throws {
    let fake = RoutingTransport()
    let snap = try await fetcher(fake).fetch(now: now)
    #expect(snap.month == "2026-11")
    #expect(snap.thisMonth == ["111111111111": 12.5, "222222222222": 3])
    #expect(snap.lastMonth == ["111111111111": 40])
    #expect(snap.estimated)
    #expect(snap.accountNames == ["111111111111": "Production"])
    #expect(fake.costCalls == 1)
}

@Test func fetcherKeepsGoingWithoutNamesWhenOrganizationsSaysNo() async throws {
    let fake = RoutingTransport()
    fake.orgStatus = 400
    fake.orgBody = #"{"__type":"AccessDeniedException","message":"You don't have permissions to access this resource."}"#
    let snap = try await fetcher(fake).fetch(now: now)
    #expect(snap.accountNames == nil)
    #expect(snap.thisMonthTotal == 15.5)
}

@Test func fetcherAsksForLastMonthThroughThisMonth() async throws {
    let fake = RoutingTransport()
    _ = try await fetcher(fake).fetch(now: now)
    let period = fake.lastCostRequestBody["TimePeriod"] as? [String: String]
    #expect(period == ["Start": "2026-10-01", "End": "2026-12-01"])
}

@Test func fetcherMapsCostExplorerErrors() async {
    let fake = RoutingTransport()
    fake.costStatus = 400
    fake.costBody = #"{"__type":"AccessDeniedException","message":"User not enabled for cost explorer access"}"#
    await #expect(throws: CostError.notEnabled) { try await fetcher(fake).fetch(now: now) }
}

@Test func clientErrorsMapToCostErrors() {
    let cases: [(AWSClientError, CostError)] = [
        (.notConnected, .notConnected),
        (.cliMissing, .cliMissing),
        (.needsSignIn(profile: "work"), .needsSignIn(profile: "work")),
        (.credentialsInvalid, .credentialsInvalid),
        (.accessDenied(message: "no"), .accessDenied),
        (.costExplorerNotEnabled, .notEnabled),
        (.network, .network),
        (.cliFailed(message: "  boom \n"), .other("boom")),
        (.service(code: "ThrottlingException", message: "Rate exceeded"), .other("Rate exceeded")),
        (.service(code: "ThrottlingException", message: ""), .other("ThrottlingException")),
    ]
    for (client, cost) in cases {
        #expect(AWSCostFetcher.explain(client) == cost)
    }
    if case .other(let message) = AWSCostFetcher.explain(AWSClientError.invalidProfileName("-x")) {
        #expect(!message.isEmpty)
    } else {
        Issue.record("invalid profile name should read as .other")
    }
    let long = String(repeating: "a", count: 500)
    if case .other(let message) = AWSCostFetcher.explain(AWSClientError.cliFailed(message: long)) {
        #expect(message.count <= 201)
    }
    #expect(AWSCostFetcher.explain(URLError(.notConnectedToInternet)) == .network)
}

// MARK: - Service

@MainActor
private struct ServiceRig {
    let suite = "x-test-\(UUID())"
    let defaults: UserDefaults
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("x-test-home-\(UUID())")
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("x-test-\(UUID())/aws-costs.json")
    let secrets = MemorySecrets()
    let fake = RoutingTransport()

    init() { defaults = UserDefaults(suiteName: suite)! }

    func service() -> AWSCostService {
        AWSCostService(defaults: defaults, home: home, secrets: secrets, transport: fake.transport, cacheURL: cache,
                       alertStore: CostAlertStore(defaults: defaults), notifier: SilentNotifier(), now: { now })
    }

    func writeAWSFiles(config: String, credentials: String) throws {
        let dir = home.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try credentials.write(to: dir.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
    }
}

/// Waits for the connect task's fetch and identity check to land.
@MainActor
private func settle(_ service: AWSCostService) async {
    // The refresh after a change starts on a later turn of the main actor; wait for it to
    // begin, then for it and the identity checks to finish, and for things to stay quiet.
    var quiet = 0
    for _ in 0..<400 where quiet < 8 {
        try? await Task.sleep(for: .milliseconds(10))
        let busy = service.monitor.isRefreshing || service.identities.count < service.connections.count
        quiet = busy ? 0 : quiet + 1
    }
}

@MainActor @Test func serviceStartsDisconnected() {
    let rig = ServiceRig()
    let service = rig.service()
    #expect(!service.isConnected)
    #expect(service.connections.isEmpty)
    #expect(service.showsTotalInMenuBar, "on until the person switches it off")
}

@MainActor @Test func connectPersistsTheChoiceWithoutSecrets() async throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "[default]\nregion = us-east-1\n",
                          credentials: "[default]\naws_access_key_id = AKIDFILE\naws_secret_access_key = file-secret\n")
    let service = rig.service()
    service.connect(.profile(name: "default"))
    await settle(service)

    #expect(service.isConnected)
    let stored = try #require(rig.defaults.data(forKey: AWSCostService.connectionsKey))
    #expect(!String(decoding: stored, as: UTF8.self).contains("file-secret"))
    #expect(service.monitor.monthToDateTotal == 15.5)
    #expect(service.identities[.profile(name: "default")]?.account == "111111111111")
    #expect(rig.fake.costCalls == 1)

    // A fresh service (a relaunch) reads the same choice back.
    #expect(rig.service().connections == [.profile(name: "default")])
}

@MainActor @Test func accessKeysAreTrimmedSavedAndRequired() async throws {
    let rig = ServiceRig()
    let service = rig.service()
    #expect(throws: AWSKeysError.empty) { try service.connectWithAccessKeys(id: "  ", secret: "s") }
    #expect(!service.isConnected)

    try service.connectWithAccessKeys(id: " AKIDPASTED\n", secret: "\tpasted-secret ")
    await settle(service)
    #expect(rig.secrets.readAccessKeys()?.id == "AKIDPASTED")
    #expect(rig.secrets.readAccessKeys()?.secret == "pasted-secret")
    #expect(service.connections == [.accessKeys])
    #expect(service.monitor.snapshot != nil)
}

@MainActor @Test func disconnectForgetsKeysChoiceAndFigures() async throws {
    let rig = ServiceRig()
    let service = rig.service()
    try service.connectWithAccessKeys(id: "AKIDPASTED", secret: "pasted-secret")
    await settle(service)
    #expect(FileManager.default.fileExists(atPath: rig.cache.path))

    service.disconnect(.accessKeys)
    #expect(rig.secrets.readAccessKeys() == nil)
    #expect(rig.defaults.data(forKey: AWSCostService.connectionsKey) == nil)
    #expect(!service.isConnected)
    #expect(service.identities.isEmpty)
    #expect(service.monitor.snapshot == nil)
    #expect(!FileManager.default.fileExists(atPath: rig.cache.path))
    #expect(rig.service().connections.isEmpty)
}

@MainActor @Test func testConnectionUsesTheFreeCallOnly() async {
    let rig = ServiceRig()
    let service = rig.service()
    let result = await service.testConnection(.accessKeys(id: "AKIDDRAFT", secret: "draft"))
    #expect(result == .success(AWSIdentity(account: "111111111111", arn: "arn:aws:iam::111111111111:user/costs")))
    #expect(rig.fake.costCalls == 0)
    #expect(rig.fake.hosts == ["sts.amazonaws.com", "organizations.us-east-1.amazonaws.com"], "both calls are free")
    // A draft isn't saved, so it doesn't count as connected.
    #expect(!service.isConnected)
    #expect(await service.testConnection(.accessKeys(id: "", secret: "x")) == .failure(.other(AWSKeysError.empty.message)))
}

@MainActor @Test func profilesListLoginsWithTheirKinds() throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(
        config: """
        [default]
        region = us-east-1
        [profile work]
        sso_session = corp
        [profile deploy]
        role_arn = arn:aws:iam::1:role/x
        source_profile = default
        [profile empty]
        region = eu-west-1
        """,
        credentials: "[default]\naws_access_key_id = AKID\naws_secret_access_key = s\n")
    let profiles = rig.service().profiles
    #expect(profiles.map(\.name) == ["default", "deploy", "work"])
    #expect(profiles.map(\.kindLabel) == ["Access keys", "Role", "SSO"])
    #expect(profiles.map(\.usesCLI) == [false, true, true])
}

@MainActor @Test func menuBarChoiceIsRemembered() {
    let rig = ServiceRig()
    rig.service().showsTotalInMenuBar = true
    #expect(rig.service().showsTotalInMenuBar)
}

@MainActor @Test func pastingNewKeysStartsFromNothing() async throws {
    let rig = ServiceRig()
    let service = rig.service()
    try service.connectWithAccessKeys(id: "AKIDFIRST", secret: "first")
    await settle(service)
    #expect(rig.fake.costCalls == 1)

    // Within the five-minute guard, but these keys may be another account's: fetch again.
    try service.connectWithAccessKeys(id: "AKIDSECOND", secret: "second")
    await settle(service)
    #expect(rig.fake.costCalls == 2)
    #expect(rig.secrets.readAccessKeys()?.id == "AKIDSECOND")
}

@MainActor @Test func checkProfilesSaysWhichLoginsWork() async throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "[profile empty]\nregion = us-east-1\n",
                          credentials: "[work]\naws_access_key_id = AKIDWORK\naws_secret_access_key = s\n[spare]\naws_access_key_id = AKIDSPARE\naws_secret_access_key = s\n")
    let service = rig.service()
    await service.checkProfiles()
    let who = AWSIdentity(account: "111111111111", arn: "arn:aws:iam::111111111111:user/costs")
    #expect(service.checks == ["work": .ready(who), "spare": .ready(who)], "profiles with no login aren't listed")
    #expect(rig.fake.costCalls == 0, "checking must never touch Cost Explorer")
    #expect(!service.isConnected, "checking connects nothing")

    let calls = rig.fake.hosts.count
    await service.checkProfiles()
    #expect(rig.fake.hosts.count == calls, "a second look within ten minutes reuses the answers")
    await service.checkProfiles(force: true)
    #expect(rig.fake.hosts.count == calls * 2)
}

@MainActor @Test func checkingAProfileReportsWhyItFails() async throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "", credentials: "[work]\naws_access_key_id = AKIDWORK\naws_secret_access_key = s\n")
    rig.fake.stsFailure = URLError(.notConnectedToInternet)
    let service = rig.service()
    await service.check("work")
    #expect(service.checks["work"] == .failed(.network))
}

@MainActor @Test func checksSayHowMuchALoginCanSee() async throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "", credentials: "[work]\naws_access_key_id = AKIDWORK\naws_secret_access_key = s\n")
    let service = rig.service()
    func scope() async -> AWSIdentity.Scope? {
        await service.check("work")
        if case .ready(let who) = service.checks["work"] { return who.scope }
        return nil
    }
    #expect(await scope() == .unknown, "AWS wouldn't say, so no guess")
    rig.fake.managementAccount = "111111111111"
    #expect(await scope() == .allAccounts)
    rig.fake.managementAccount = "999999999999"
    #expect(await scope() == .oneAccount)
}

@MainActor @Test func oneAccountLoginGetsAHintNamingAWiderOne() async throws {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "", credentials: "[work]\naws_access_key_id = AKIDWORK\naws_secret_access_key = s\n")
    rig.fake.managementAccount = "999999999999"
    // A member account may not list the organization's accounts, so it gets no names from AWS.
    rig.fake.orgStatus = 400
    rig.fake.orgBody = #"{"__type":"AccessDeniedException","message":"no"}"#
    let service = rig.service()
    #expect(service.pageNote == nil)
    service.connect(.profile(name: "work"))
    await settle(service)
    #expect(service.pageNote == "This login sees one AWS account. Add your other logins to see them together.")
    // The one account still gets a readable name: the profile that signed in to it.
    #expect(service.monitor.accounts.first { $0.accountId == "111111111111" }?.displayName == "work")
}

@Test func profilesNameTheAccountsTheyPointAt() {
    let config = """
    [profile shop]
    sso_session = main
    sso_account_id = 222222222222
    [profile ops]
    role_arn = arn:aws:iam::333333333333:role/OrganizationAccountAccessRole
    source_profile = shop
    [profile also-shop]
    sso_account_id = 222222222222
    [profile plain]
    region = us-east-1
    """
    #expect(AWSProfiles.accountNames(configContents: config, credentialsContents: "")
            == ["222222222222": "also-shop", "333333333333": "ops"], "first profile by name wins a shared account")
    #expect(AWSProfiles.accountId(inARN: "arn:aws:iam::123456789012:role/x") == "123456789012")
    #expect(AWSProfiles.accountId(inARN: "arn:aws:iam::role/x") == nil)
}

@Test func organizationNamesWinOverLocalOnes() {
    let snap = CostSnapshot(fetchedAt: now, currency: "USD", month: CostMath.month(now),
                            thisMonth: ["1": 5, "2": 3, "3": 1], lastMonth: [:], estimated: true,
                            accountNames: ["1": "Production"])
    let names = CostMath.accounts(snapshot: snap, now: now, fallbackNames: ["1": "prod-profile", "2": "shop"])
        .map(\.displayName)
    #expect(names == ["Production", "shop", "Account 3"])
}

@MainActor @Test func menuBarTotalIsOnUntilSwitchedOff() {
    let rig = ServiceRig()
    #expect(rig.service().showsTotalInMenuBar)
    rig.service().showsTotalInMenuBar = false
    #expect(!rig.service().showsTotalInMenuBar)
}

// MARK: - Several logins

/// Three static-key profiles: `a` sees account 1, `b` sees account 2, `wide` sees both and a third.
@MainActor
private func severalLogins() throws -> ServiceRig {
    let rig = ServiceRig()
    try rig.writeAWSFiles(config: "", credentials: """
    [a]
    aws_access_key_id = AKIDA
    aws_secret_access_key = s
    [b]
    aws_access_key_id = AKIDB
    aws_secret_access_key = s
    [wide]
    aws_access_key_id = AKIDWIDE
    aws_secret_access_key = s
    """)
    rig.fake.costByKey = [
        "AKIDA": (200, RoutingTransport.costs(["111111111111": 10])),
        "AKIDB": (200, RoutingTransport.costs(["222222222222": 5])),
        "AKIDWIDE": (200, RoutingTransport.costs(["111111111111": 10, "222222222222": 5, "333333333333": 2])),
    ]
    rig.fake.accountByKey = ["AKIDA": "111111111111", "AKIDB": "222222222222", "AKIDWIDE": "333333333333"]
    rig.fake.orgStatus = 400
    rig.fake.orgBody = #"{"__type":"AccessDeniedException","message":"no"}"#
    return rig
}

@MainActor @Test func severalLoginsAreShownTogetherAndTotalled() async throws {
    let rig = try severalLogins()
    let service = rig.service()
    service.connect(.profile(name: "a"))
    service.connect(.profile(name: "b"))
    await settle(service)
    #expect(service.monitor.accounts.map(\.accountId) == ["111111111111", "222222222222"])
    #expect(service.monitor.monthToDateTotal == 15)
    #expect(service.monitor.accounts.map(\.displayName) == ["a", "b"], "each named after its login")
    #expect(service.pageNote == nil)
    // A relaunch reads the same list back.
    #expect(rig.service().connections == [.profile(name: "a"), .profile(name: "b")])
}

@MainActor @Test func addingALoginPaysOnlyForThatLogin() async throws {
    let rig = try severalLogins()
    let service = rig.service()
    service.connect(.profile(name: "a"))
    await settle(service)
    #expect(rig.fake.costCalls == 1)
    service.connect(.profile(name: "b"))
    await settle(service)
    #expect(rig.fake.costCalls == 2, "a's reading is minutes old and is kept")
    #expect(service.monitor.monthToDateTotal == 15)
}

@MainActor @Test func removingALoginDropsItsAccountsWithoutPaying() async throws {
    let rig = try severalLogins()
    let service = rig.service()
    service.connect(.profile(name: "a"))
    service.connect(.profile(name: "b"))
    await settle(service)
    let calls = rig.fake.costCalls
    service.disconnect(.profile(name: "b"))
    await settle(service)
    #expect(service.monitor.accounts.map(\.accountId) == ["111111111111"])
    #expect(service.monitor.monthToDateTotal == 10)
    #expect(rig.fake.costCalls == calls)
    #expect(service.isConnected)
}

@MainActor @Test func anAccountTwoLoginsSeeCountsOnce() async throws {
    let rig = try severalLogins()
    let service = rig.service()
    service.connect(.profile(name: "a"))
    service.connect(.profile(name: "wide"))
    await settle(service)
    #expect(service.monitor.monthToDateTotal == 17)
    #expect(service.monitor.accounts.count == 3)
    #expect(service.coveredBy(.profile(name: "a")) == .profile(name: "wide"), "a adds a request and no accounts")
    #expect(service.coveredBy(.profile(name: "wide")) == nil)
}

@MainActor @Test func aLoginThatFailsLeavesTheOthersStanding() async throws {
    let rig = try severalLogins()
    rig.fake.costByKey["AKIDB"] = (400, #"{"__type":"ExpiredTokenException","message":"expired"}"#)
    let service = rig.service()
    service.connect(.profile(name: "a"))
    service.connect(.profile(name: "b"))
    await settle(service)
    #expect(service.monitor.monthToDateTotal == 10)
    #expect(service.monitor.error == nil, "the page still has figures to show")
    #expect(service.fetchProblems[.profile(name: "b")] != nil)
    #expect(service.pageNote == "B couldn't be read, so its accounts are missing from the total.")
}

@MainActor @Test func aLoginSavedByAnEarlierBuildIsKept() throws {
    let rig = ServiceRig()
    rig.defaults.set(try JSONEncoder().encode(AWSConnection.profile(name: "old")), forKey: AWSCostService.legacyConnectionKey)
    #expect(rig.service().connections == [.profile(name: "old")])
}

@Test func mergingKeepsTheOldestTimeAndPoolsNames() {
    let earlier = now.addingTimeInterval(-600)
    let one = CostSnapshot(fetchedAt: now, currency: "USD", month: "2026-11", thisMonth: ["1": 4], lastMonth: ["1": 8],
                           estimated: false, accountNames: ["1": "Production"])
    let two = CostSnapshot(fetchedAt: earlier, currency: "USD", month: "2026-11", thisMonth: ["1": 4, "2": 1], lastMonth: [:],
                           estimated: true, accountNames: ["2": "Staging"])
    let merged = CostMath.merge([one, two])
    #expect(merged?.thisMonth == ["1": 4, "2": 1])
    #expect(merged?.lastMonthTotal == 8)
    #expect(merged?.fetchedAt == earlier)
    #expect(merged?.estimated == true)
    #expect(merged?.accountNames == ["1": "Production", "2": "Staging"])
    #expect(CostMath.merge([]) == nil)
}
