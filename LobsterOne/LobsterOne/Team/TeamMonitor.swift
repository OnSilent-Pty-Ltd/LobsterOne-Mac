import Combine
import Foundation

/// Holds the latest crew snapshot for the popover's Team page. Scans off the main thread and
/// no more often than `minimumInterval`, since a scan walks a week of transcripts.
@MainActor
final class TeamMonitor: ObservableObject {
    static let minimumInterval: TimeInterval = 60
    /// The switch for the Agents page. On for everyone; it can still be turned off by hand:
    /// `defaults write <bundle id> teamTabEnabled -bool NO`.
    nonisolated static let enabledKey = "teamTabEnabled"

    /// On unless someone has switched it off. Read through here, so every part of the app agrees.
    nonisolated static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
    /// A member counts as working for this long after its transcript was last written to.
    static let workingWindow: TimeInterval = 20

    @Published private(set) var snapshot: TeamSnapshot?
    @Published private(set) var isRefreshing = false
    /// How far the scan in flight has got through the week's transcripts, from 0 to 1; nil when none is running.
    @Published private(set) var progress: Double?
    /// What needs the person's eye, and what has changed since they last looked.
    @Published private(set) var report = CrewReport()
    /// Attention the menu bar still shows a dot for.
    @Published private(set) var unnoticed: [CrewAttention] = []
    /// Crew members with a run in progress, by agent name.
    @Published private(set) var working: [String] = []
    /// The latest weekly digest, if one has been written.
    @Published private(set) var digest: CrewDigest?
    @Published private(set) var isPreparingDigest = false
    /// Why the last attempt at a digest failed, in words for the person.
    @Published private(set) var digestProblem: String?

    /// Called with attention that has not been announced before.
    var onNewAttention: (([CrewAttention]) -> Void)?

    private let scan: @Sendable (Date, @escaping TeamScanner.Progress) -> TeamSnapshot
    private let crew: @Sendable () -> [TeamMember]
    let keeper: CrewKeeper?
    private let now: () -> Date
    private var lastSeenWorking: [String: Date] = [:]

    init(claudeDirectory: URL = TeamScanner.defaultClaudeDirectory, keeper: CrewKeeper? = CrewKeeper(),
         now: @escaping () -> Date = Date.init) {
        let cache = TeamScanner.Cache()
        self.scan = { TeamScanner.scan(claudeDirectory: claudeDirectory, now: $0, cache: cache, progress: $1) }
        self.crew = { TeamScanner.crew(claudeDirectory: claudeDirectory) }
        self.keeper = keeper
        self.now = now
    }

    /// For tests and previews: a canned scan, and optionally a canned crew with a real keeper.
    init(scan: @escaping @Sendable (Date) -> TeamSnapshot, crew: @escaping @Sendable () -> [TeamMember] = { [] },
         keeper: CrewKeeper? = nil, now: @escaping () -> Date = Date.init) {
        self.scan = { date, _ in scan(date) }
        self.crew = crew
        self.keeper = keeper
        self.now = now
    }

    /// The Team page came into view.
    func menuOpened() async {
        await refresh(ifOlderThan: Self.minimumInterval)
    }

    func refresh(ifOlderThan maxAge: TimeInterval = 0) async {
        guard !isRefreshing else { return }
        let current = now()
        if let snapshot, current.timeIntervalSince(snapshot.scannedAt) < maxAge { return }
        isRefreshing = true
        progress = 0
        let scan = scan
        let report: TeamScanner.Progress = { [weak self] fraction in
            Task { @MainActor in self?.noteProgress(fraction) }
        }
        let fresh = await Task.detached(priority: .utility) { scan(current, report) }.value
        snapshot = fresh
        isRefreshing = false
        progress = nil
        await check(fresh.members)
    }

    /// Reports arrive from the scanning thread and can land late or out of order: only move forward, and only mid-scan.
    private func noteProgress(_ fraction: Double) {
        guard isRefreshing, let current = progress, fraction > current else { return }
        progress = fraction
    }

    // MARK: - Keeping

    /// A charter or notebook changed on disk: record it and look for anything that needs attention.
    /// Cheap; does not rescan the week's runs.
    func checkCrew() async {
        let crew = crew
        await check(await Task.detached(priority: .utility) { crew() }.value)
    }

    private func check(_ members: [TeamMember]) async {
        guard let keeper else { return }
        let current = now()
        let (report, fresh, unnoticed, digest) = await Task.detached(priority: .utility) {
            let report = keeper.check(members, now: current)
            return (report, keeper.takeUnannounced(report.attention), keeper.unnoticed(report.attention),
                    CrewDigestWriter(keeper: keeper).latest())
        }.value
        if self.report != report { self.report = report }
        if self.digest != digest { self.digest = digest }
        if self.unnoticed != unnoticed { self.unnoticed = unnoticed }
        if !fresh.isEmpty { onNewAttention?(fresh) }
    }

    /// The popover was opened: the menu bar dot has done its job.
    func markNoticed() {
        guard !unnoticed.isEmpty, let keeper else { return }
        keeper.markNoticed(unnoticed)
        unnoticed = []
    }

    func changes(for member: String) -> [CrewKeeper.Change] {
        keeper?.changes(for: member) ?? []
    }

    /// The person has looked at a member's changes.
    func markSeen(_ member: String) async {
        keeper?.markSeen(member)
        await checkCrew()
    }

    func acceptCharter(_ member: String) async {
        do { try keeper?.installer.acceptCharter(agentNamed: member) } catch { Self.log("accept", member, error) }
        await refresh()
    }

    func restoreCharter(_ member: String) async {
        do { try keeper?.installer.restoreCharter(agentNamed: member) } catch { Self.log("restore", member, error) }
        await refresh()
    }

    // MARK: - Digest

    /// Has Aurelia read the week and write it up: one headless Claude Code run on the person's own plan.
    /// Only ever started by the person.
    func prepareDigest(claudePath: String? = ClaudeCredentialService.resolveClaudeBinary()) async {
        guard let keeper, !isPreparingDigest else { return }
        isPreparingDigest = true
        digestProblem = nil
        await refresh()
        let members = snapshot?.members ?? []
        let report = report
        let current = now()
        do {
            _ = try await CrewDigestWriter(keeper: keeper).prepare(members: members, report: report, claudePath: claudePath, now: current)
        } catch {
            digestProblem = error.localizedDescription
            DebugLog.shared.log("Crew digest failed: \(error.localizedDescription)")
        }
        isPreparingDigest = false
        await checkCrew()
    }

    func setDecision(_ id: Int, done: Bool) async {
        guard let keeper, let digest else { return }
        do { self.digest = try CrewDigestWriter(keeper: keeper).setDecision(id, done: done, in: digest) } catch {
            DebugLog.shared.log("Crew: could not update the digest: \(error.localizedDescription)")
        }
        await checkCrew()
    }

    /// The owner's ruling on a finding, written into the reviewer's own log so it is read next time.
    func mark(_ status: CrewFinding.Status, finding id: String, for member: String) async {
        guard let target = snapshot?.members.first(where: { $0.name == member }) else { return }
        do { try CrewFindings.mark(status, finding: id, for: target) } catch {
            DebugLog.shared.log("Crew: could not update \(member)'s ledger: \(error.localizedDescription)")
        }
        await checkCrew()
    }

    private static func log(_ action: String, _ member: String, _ error: Error) {
        DebugLog.shared.log("Crew: could not \(action) \(member)'s charter: \(error.localizedDescription)")
    }

    // MARK: - Working

    /// A crew member's transcript was just written to.
    func sawActivity(agent: String, at date: Date) {
        lastSeenWorking[agent] = date
        updateWorking(at: date)
    }

    /// Drops members whose runs have gone quiet.
    func updateWorking(at date: Date) {
        lastSeenWorking = lastSeenWorking.filter { date.timeIntervalSince($0.value) < Self.workingWindow }
        let names = lastSeenWorking.keys.sorted()
        if names != working { working = names }
    }

    /// Who the agent name belongs to, for the menu bar: nil unless they are on the crew.
    func member(named agent: String) -> TeamMember? {
        snapshot?.members.first { $0.name == agent }
    }
}
