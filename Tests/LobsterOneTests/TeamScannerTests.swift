import Testing
import Foundation
@testable import LobsterOne

/// A throwaway `~/.claude` with charters, notebooks and subagent runs.
private final class FakeClaudeHome {
    let root: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("team-scanner-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    func write(_ text: String, to path: String, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func charter(_ name: String, extra: String = "") throws {
        try write("---\nname: \(name)\ndescription: Does \(name) things\n\(extra)---\nYou are \(name).\n", to: "agents/\(name).md")
    }

    /// One subagent run: a meta file naming the agent beside a transcript with one usage line per entry.
    func run(agent: String, id: String, project: String = "-Users-me-app", session: String = "s1",
             cwd: String = "/Users/me/app", lines: [(at: Date, input: Int, output: Int)], modified: Date) throws {
        let base = "projects/\(project)/\(session)/subagents/agent-\(id)"
        try write(#"{"agentType":"\#(agent)","model":"claude-opus-5-5"}"#, to: base + ".meta.json")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = lines.map { line in
            #"{"type":"assistant","timestamp":"\#(stamp.string(from: line.at))","cwd":"\#(cwd)","isSidechain":true,"agentId":"\#(id)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":\#(line.input),"output_tokens":\#(line.output),"cache_read_input_tokens":9999}}}"#
        }.joined(separator: "\n") + "\n"
        try write(body, to: base + ".jsonl", modified: modified)
    }
}

private let now = Date(timeIntervalSince1970: 1_795_000_000)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

struct TeamScannerTests {
    @Test func frontmatterReadsTopLevelScalars() {
        let fields = TeamScanner.frontmatter("""
        ---
        name: release-reviewer
        description: "Bram. Reviews a change: before it ships."
        model: opus
        memory: user
        hooks:
          PreToolUse:
            - matcher: "Write"
        ---
        name: not-this-one
        """)
        #expect(fields["name"] == "release-reviewer")
        #expect(fields["description"] == "Bram. Reviews a change: before it ships.")
        #expect(fields["model"] == "opus")
        #expect(fields["memory"] == "user")
        #expect(fields["matcher"] == nil)
    }

    @Test func frontmatterNeedsBothFences() {
        #expect(TeamScanner.frontmatter("name: loose\n").isEmpty)
        #expect(TeamScanner.frontmatter("---\nname: unclosed\n").isEmpty)
    }

    @Test func chartersSkipFilesWithoutAName() throws {
        let home = try FakeClaudeHome()
        try home.charter("security-reviewer", extra: "memory: user\n")
        try home.write("Just notes, no frontmatter.\n", to: "agents/notes.md")
        try home.write("---\ndescription: nameless\n---\n", to: "agents/nameless.md")
        try home.write("{}", to: "agents/ignored.json")

        let members = TeamScanner.charters(in: home.root.appendingPathComponent("agents"))
        #expect(members.map(\.name) == ["security-reviewer"])
        #expect(members.first?.memoryScope == "user")
        #expect(members.first?.charterModified != nil)
    }

    @Test func notebookCountsLinesAndWarnsNearTheLimit() throws {
        let home = try FakeClaudeHome()
        try home.write("one\ntwo\nthree", to: "small.md")
        try home.write(String(repeating: "a line\n", count: 180), to: "long.md")
        try home.write(String(repeating: "x", count: 23_000), to: "heavy.md")

        let small = try #require(TeamScanner.notebook(at: home.root.appendingPathComponent("small.md")))
        #expect(small.lines == 3)
        #expect(!small.isNearlyFull)
        #expect(TeamScanner.notebook(at: home.root.appendingPathComponent("long.md"))?.lines == 180)
        #expect(TeamScanner.notebook(at: home.root.appendingPathComponent("long.md"))?.isNearlyFull == true)
        #expect(TeamScanner.notebook(at: home.root.appendingPathComponent("heavy.md"))?.isNearlyFull == true)
        #expect(TeamScanner.notebook(at: home.root.appendingPathComponent("missing.md")) == nil)
    }

    @Test func usageSumsInputAndOutputPerAgentInsideTheWindow() throws {
        let home = try FakeClaudeHome()
        try home.run(agent: "security-reviewer", id: "a1", lines: [(ago(1), 100, 20), (ago(1), 50, 5)], modified: ago(1))
        try home.run(agent: "security-reviewer", id: "a2", session: "s2", cwd: "/Users/me/Robocog---Mac/.claude/worktrees/fix",
                     lines: [(ago(0.1), 10, 1)], modified: ago(0.1))
        try home.run(agent: "Explore", id: "a3", lines: [(ago(2), 7, 3)], modified: ago(2))
        // Finished before the window opened: not counted at all.
        try home.run(agent: "Explore", id: "old", lines: [(ago(9), 1000, 1000)], modified: ago(9))
        // Still being written to, but its early lines fall outside the window.
        try home.run(agent: "general-purpose", id: "long", lines: [(ago(8), 500, 500), (ago(3), 40, 2)], modified: ago(3))

        let usage = TeamScanner.usageByAgent(projects: home.root.appendingPathComponent("projects"), now: now)
        #expect(usage["security-reviewer"]?.runs == 2)
        #expect(usage["security-reviewer"]?.tokens == 186)
        #expect(usage["security-reviewer"]?.lastRun == ago(0.1))
        #expect(usage["security-reviewer"]?.lastProject == "Robocog---Mac")
        #expect(usage["security-reviewer"]?.lastModel == "claude-opus-5-5")
        #expect(usage["Explore"]?.runs == 1)
        #expect(usage["Explore"]?.tokens == 10)
        #expect(usage["general-purpose"]?.tokens == 42)
    }

    @Test func runsWithoutAMetaFileOrTokensAreLeftOut() throws {
        let home = try FakeClaudeHome()
        try home.write("{\"type\":\"assistant\"}\n", to: "projects/p/s/subagents/agent-x.jsonl", modified: ago(1))
        try home.run(agent: "Explore", id: "empty", lines: [], modified: ago(1))
        #expect(TeamScanner.usageByAgent(projects: home.root.appendingPathComponent("projects"), now: now).isEmpty)
    }

    @Test func scanCountsOnlyTheCrewBusiestFirst() throws {
        let home = try FakeClaudeHome()
        try home.charter("security-reviewer", extra: "memory: user\n")
        try home.charter("release-reviewer", extra: "memory: project\n")
        try home.charter("data-analyst")
        try home.write("- accepted risk: none yet\n", to: "agent-memory/security-reviewer/MEMORY.md")
        try home.run(agent: "release-reviewer", id: "r1", lines: [(ago(1), 300, 30)], modified: ago(1))
        try home.run(agent: "security-reviewer", id: "w1", lines: [(ago(1), 100, 10)], modified: ago(1))
        try home.run(agent: "Explore", id: "e1", lines: [(ago(1), 5, 5)], modified: ago(1))
        try home.run(agent: "general-purpose", id: "g1", lines: [(ago(1), 900, 100)], modified: ago(1))

        let snapshot = TeamScanner.scan(claudeDirectory: home.root, now: now)
        #expect(snapshot.members.map(\.name) == ["release-reviewer", "security-reviewer", "data-analyst"])
        #expect(snapshot.crewTokens == 440)
        #expect(snapshot.crewRuns == 2)
        #expect(snapshot.members[1].notebook?.lines == 1)
        // Project-scoped memory has no single folder to read.
        #expect(snapshot.members[0].notebook == nil)
        #expect(snapshot.members[2].usage == AgentUsage())
    }

    @Test func scanOfAnEmptyHomeIsEmpty() throws {
        let home = try FakeClaudeHome()
        let snapshot = TeamScanner.scan(claudeDirectory: home.root, now: now)
        #expect(snapshot.members.isEmpty)
    }

    @Test func cachedCountsAreReusedUntilTheFileChanges() throws {
        let home = try FakeClaudeHome()
        let cache = TeamScanner.Cache()
        let projects = home.root.appendingPathComponent("projects")
        try home.run(agent: "Explore", id: "e1", lines: [(ago(1), 10, 0)], modified: ago(1))
        #expect(TeamScanner.usageByAgent(projects: projects, now: now, cache: cache)["Explore"]?.tokens == 10)

        // Same size and date: the cached count stands even though the content differs.
        try home.run(agent: "Explore", id: "e1", lines: [(ago(1), 99, 0)], modified: ago(1))
        #expect(TeamScanner.usageByAgent(projects: projects, now: now, cache: cache)["Explore"]?.tokens == 10)

        try home.run(agent: "Explore", id: "e1", lines: [(ago(1), 99, 0), (ago(0.5), 1, 0)], modified: ago(0.5))
        #expect(TeamScanner.usageByAgent(projects: projects, now: now, cache: cache)["Explore"]?.tokens == 100)

        // Six and a half days on, the first line has left the window: counted again, not reused.
        let later = now.addingTimeInterval(6.2 * 86_400)
        #expect(TeamScanner.usageByAgent(projects: projects, now: later, cache: cache)["Explore"]?.tokens == 1)
    }

    @Test func progressClimbsFromNothingToAllOfIt() throws {
        let home = try FakeClaudeHome()
        for n in 0..<12 {
            try home.run(agent: "Explore", id: "e\(n)", session: "s\(n)", lines: Array(repeating: (ago(1), 10, 1), count: 1 + n * 3), modified: ago(1))
        }
        // Outside the window: neither read nor counted towards progress.
        try home.run(agent: "Explore", id: "old", lines: Array(repeating: (ago(9), 10, 1), count: 500), modified: ago(9))

        final class Seen: @unchecked Sendable { var values: [Double] = [] }
        let seen = Seen()
        let usage = TeamScanner.usageByAgent(projects: home.root.appendingPathComponent("projects"), now: now) { seen.values.append($0) }
        #expect(usage["Explore"]?.runs == 12)
        #expect(seen.values.first == 0)
        #expect(seen.values.last == 1)
        #expect(seen.values == seen.values.sorted())
        #expect(seen.values.count > 3)
        #expect(seen.values.allSatisfy { (0...1).contains($0) })
    }

    @Test func progressFinishesEvenWithNothingToRead() throws {
        let home = try FakeClaudeHome()
        final class Seen: @unchecked Sendable { var values: [Double] = [] }
        let seen = Seen()
        _ = TeamScanner.usageByAgent(projects: home.root.appendingPathComponent("projects"), now: now) { seen.values.append($0) }
        #expect(seen.values.isEmpty)
        try home.charter("x")
        _ = TeamScanner.scan(claudeDirectory: home.root, now: now) { seen.values.append($0) }
        #expect(seen.values.isEmpty)
        try home.write("{}", to: "projects/p/s/subagents/readme.txt")
        _ = TeamScanner.usageByAgent(projects: home.root.appendingPathComponent("projects"), now: now) { seen.values.append($0) }
        #expect(seen.values == [0, 1])
    }

    @Test func runsByOtherAgentsAreSkippedUnread() throws {
        let home = try FakeClaudeHome()
        try home.charter("security-reviewer")
        try home.run(agent: "security-reviewer", id: "w1", lines: [(ago(1), 100, 10)], modified: ago(1))
        try home.run(agent: "general-purpose", id: "g1", lines: Array(repeating: (ago(1), 900, 100), count: 400), modified: ago(1))
        let projects = home.root.appendingPathComponent("projects")

        // Unfiltered, both are counted and cached; filtered to the crew, the big run never enters the cache.
        let everything = TeamScanner.Cache()
        #expect(TeamScanner.usageByAgent(projects: projects, now: now, cache: everything).count == 2)
        #expect(everything.paths.contains { $0.hasSuffix("/subagents/agent-g1.jsonl") })
        let cache = TeamScanner.Cache()
        let usage = TeamScanner.usageByAgent(projects: projects, now: now, only: ["security-reviewer"], cache: cache)
        #expect(usage.keys.sorted() == ["security-reviewer"])
        #expect(cache.paths.count == 1)
        #expect(cache.paths.first?.hasSuffix("/subagents/agent-w1.jsonl") == true)

        // Progress is measured against the crew's runs alone, and with no crew nothing is read at all.
        final class Seen: @unchecked Sendable { var values: [Double] = [] }
        let seen = Seen()
        _ = TeamScanner.scan(claudeDirectory: home.root, now: now) { seen.values.append($0) }
        #expect(seen.values == [0, 1])
        #expect(TeamScanner.usageByAgent(projects: projects, now: now, only: []).isEmpty)
    }

    @Test func projectNameDropsWorktreeFolders() {
        #expect(TeamScanner.projectName(cwd: "/Users/me/Desktop/LobsterOne/Robocog---Mac") == "Robocog---Mac")
        #expect(TeamScanner.projectName(cwd: "/Users/me/site/.claude/worktrees/aws-costs-page") == "site")
        #expect(TeamScanner.projectName(cwd: "/Users/me/site/.worktrees/x/y") == "site")
    }
}

@MainActor
struct TeamMonitorTests {
    private final class Counter: @unchecked Sendable { var scans = 0 }

    @Test func menuOpenedScansAtMostOncePerInterval() async {
        let counter = Counter()
        var clock = now
        let monitor = TeamMonitor(scan: { at in
            counter.scans += 1
            return TeamSnapshot(scannedAt: at, members: [])
        }, now: { clock })

        await monitor.menuOpened()
        await monitor.menuOpened()
        #expect(counter.scans == 1)

        clock = now.addingTimeInterval(TeamMonitor.minimumInterval + 1)
        await monitor.menuOpened()
        #expect(counter.scans == 2)
        #expect(monitor.snapshot?.scannedAt == clock)

        await monitor.refresh()
        #expect(counter.scans == 3)
        #expect(!monitor.isRefreshing)
        // Progress belongs to a scan in flight; none is.
        #expect(monitor.progress == nil)
    }
}

struct TeamFormatTests {
    @Test func titleReadsAnAgentNameAsWords() {
        #expect(TeamFormat.title("security-reviewer") == "Security reviewer")
        #expect(TeamFormat.title("data_analyst") == "Data analyst")
        #expect(TeamFormat.title("Explore") == "Explore")
    }

    @Test func shareNeedsAWeekNoSmallerThanTheCrew() {
        #expect(TeamFormat.share(110, of: 1000) == 0.11)
        #expect(TeamFormat.share(0, of: 1000) == 0)
        #expect(TeamFormat.share(110, of: nil) == nil)
        #expect(TeamFormat.share(110, of: 0) == nil)
        // The week's total comes from the server and can lag behind what is on disk.
        #expect(TeamFormat.share(1200, of: 1000) == nil)
    }

    @Test func percentKeepsASliverVisible() {
        #expect(TeamFormat.percent(0.114) == "11%")
        #expect(TeamFormat.percent(0.004) == "<1%")
        #expect(TeamFormat.percent(0) == "0%")
        #expect(TeamFormat.percent(1) == "100%")
    }

    @Test func signedUsesATrueMinus() {
        #expect(TeamFormat.signed(6) == "+6")
        #expect(TeamFormat.signed(-2) == "\u{2212}2")
    }

    @Test func runsArePluralised() {
        #expect(TeamFormat.runs(1) == "1 run")
        #expect(TeamFormat.runs(19) == "19 runs")
    }

    @Test func whenGoesFromMinutesToDatesAsTimePasses() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Thursday 19 November 2026, 14:00 UTC.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14))!
        func when(_ hoursAgo: Double) -> String {
            TeamFormat.when(now.addingTimeInterval(-hoursAgo * 3600), now: now, calendar: calendar)
        }
        #expect(when(0) == "just now")
        #expect(when(0.2) == "12m ago")
        #expect(when(2) == "2h ago")
        #expect(when(13) == "13h ago")
        #expect(when(20) == "yesterday")
        #expect(when(24 * 3) == "Monday")
        #expect(when(24 * 7) == "12 Nov")
    }

    @Test func modelPrefersTheCharterThenTheLastRun() {
        #expect(TeamFormat.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(TeamFormat.modelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(TeamFormat.modelName("opus") == "Opus")
        #expect(TeamFormat.model(charter: "sonnet", lastRun: "claude-opus-5-5") == "Sonnet")
        #expect(TeamFormat.model(charter: "inherit", lastRun: "claude-opus-5-5") == "Opus 5.5")
        #expect(TeamFormat.model(charter: nil, lastRun: nil) == "The session's model")
    }
}

struct PopoverPageTests {
    @Test func theAgentsPageIsOnUnlessSwitchedOff() throws {
        let name = "agents-tab-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TeamMonitor.isEnabled(defaults))
        defaults.set(false, forKey: TeamMonitor.enabledKey)
        #expect(!TeamMonitor.isEnabled(defaults))
        defaults.set(true, forKey: TeamMonitor.enabledKey)
        #expect(TeamMonitor.isEnabled(defaults))
    }

    @Test func thePagesReadCodeAgentsInfra() {
        #expect([PopoverPage.claude, .team, .aws].map(\.title) == ["Code", "Agents", "Infra"])
        // The stored value is unchanged, so the page someone had open is still remembered.
        #expect(PopoverPage(rawValue: "team") == .team)
    }
}

struct ToolChipTests {
    private func source(configured: Bool = true, status: String? = nil, seen: Date? = nil) -> SourceStatus {
        SourceStatus(id: "codex", displayName: "Codex", keyPrefix: nil, lastSeenAt: seen, todayTokens: 0,
                     backendStatus: status, isConfigured: configured, percentUsed: 0)
    }

    @Test @MainActor func hoveringAChipSaysItsStatus() {
        #expect(MenuPopoverView.chipHelp(source(seen: Date())) == "Waiting. Last seen just now")
        #expect(MenuPopoverView.chipHelp(source(status: "active", seen: Date())) == "Active. Last seen just now")
        #expect(MenuPopoverView.chipHelp(source()) == "Waiting for first data")
        #expect(MenuPopoverView.chipHelp(source(configured: false)) == "Off")
    }
}

struct CrewPortraitTests {
    @Test func aPortraitIsResampledToTheSizeItIsShownAt() {
        #expect(CrewPortrait.image("wren", pixels: 72)?.width == 72)
        #expect(CrewPortrait.image("wren", pixels: 168)?.width == 168)
        #expect(CrewPortrait.image("../wren", pixels: 72) == nil)
    }
}

struct AppWindowTests {
    @Test func everyWindowSharesOneSize() {
        #expect(AppWindow.size == CGSize(width: 870, height: 790))
        #expect(SettingsTab.windowWidth == 870 && SettingsTab.windowHeight == 790)
    }

    @Test func diagnosticsAndLogsAreReachedFromAboutNotFromTheBar() {
        #expect(SettingsTab.shown.map(\.title) == ["Preferences", "Notifications", "Sounds", "Tools", "Screensaver", "Account", "AWS", "About"])
        #expect(SettingsTab.diagnostics.isUnderAbout && SettingsTab.logs.isUnderAbout && !SettingsTab.about.isUnderAbout)
        // The shortcuts follow the bar: About takes the number Diagnostics had.
        #expect(SettingsTab.about.shortcutNumber == 8)
        #expect(SettingsTab.diagnostics.shortcutNumber == nil && SettingsTab.logs.shortcutNumber == nil)
    }
}
