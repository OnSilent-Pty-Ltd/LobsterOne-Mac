import Testing
import AppKit
import Foundation
@testable import LobsterOne

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let start = Date(timeIntervalSince1970: 1_795_000_000)
private func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

struct CrewHistoryTests {
    @Test func recordsOnlyWhenTheContentChanges() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = CrewHistory(supportDirectory: home)

        #expect(history.record("bram", .notebook, content: Data("one\n".utf8), at: day(0)))
        #expect(!history.record("bram", .notebook, content: Data("one\n".utf8), at: day(1)))
        #expect(history.record("bram", .notebook, content: Data("one\ntwo\n".utf8), at: day(2)))

        let versions = history.versions("bram", .notebook)
        #expect(versions.map(\.date) == [day(0), day(2)])
        #expect(history.text(versions[1]) == "one\ntwo\n")
        #expect(history.versions("bram", .charter).isEmpty)
        #expect(history.versions("wren", .notebook).isEmpty)
    }

    @Test func keepsTheNewestFiftyVersions() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = CrewHistory(supportDirectory: home)
        for n in 0..<(CrewHistory.keep + 5) {
            history.record("bram", .notebook, content: Data("\(n)".utf8), at: day(Double(n)))
        }
        let versions = history.versions("bram", .notebook)
        #expect(versions.count == CrewHistory.keep)
        #expect(history.text(versions[0]) == "5")
        #expect(history.text(versions.last!) == "\(CrewHistory.keep + 4)")
    }

    @Test func aClockSetBackStillSortsAfterTheLatest() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = CrewHistory(supportDirectory: home)
        history.record("bram", .charter, content: Data("a".utf8), at: day(2))
        history.record("bram", .charter, content: Data("b".utf8), at: day(1))
        #expect(history.versions("bram", .charter).map(history.text) == ["a", "b"])
    }

    @Test func anAgentNameCannotEscapeTheHistoryFolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = CrewHistory(supportDirectory: home)
        #expect(history.record("../../escape", .charter, content: Data("x".utf8), at: day(0)))
        let saved = history.versions("../../escape", .charter)
        #expect(saved.count == 1)
        #expect(saved[0].url.resolvingSymlinksInPath().path.hasPrefix(history.directory.resolvingSymlinksInPath().path + "/"))
        #expect(!history.record("", .charter, content: Data("x".utf8), at: day(0)))
    }
}

struct LineDiffTests {
    @Test func marksAddedAndRemovedLinesInOrder() {
        let lines = LineDiff.lines(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(LineDiff.counts(lines) == (2, 1))
    }

    @Test func identicalTextHasNoChanges() {
        let lines = LineDiff.lines(old: "a\nb\n", new: "a\nb")
        #expect(lines.allSatisfy { $0.kind == .same })
        #expect(LineDiff.collapsed(lines).isEmpty)
    }

    @Test func collapsedKeepsContextAndFoldsTheRest() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n10\n", with: "\nten\n")
        let collapsed = LineDiff.collapsed(LineDiff.lines(old: old, new: new), context: 2)
        #expect(collapsed.map(\.text) == ["", "8", "9", "10", "ten", "11", "12", ""])
        #expect(collapsed.first?.kind == .gap)
        #expect(collapsed.last?.kind == .gap)
    }

    @Test func fromNothingEverythingIsAdded() {
        #expect(LineDiff.lines(old: "", new: "x\ny\n").map(\.kind) == [.added, .added])
    }
}

struct CrewKeeperTests {
    private let home: URL
    private let installer: CrewInstaller
    private let keeper: CrewKeeper

    init() throws {
        home = try tempHome()
        installer = CrewInstaller(homeDirectory: home)
        keeper = CrewKeeper(installer: installer)
    }

    private var crew: [TeamMember] { TeamScanner.crew(claudeDirectory: home.appendingPathComponent(".claude")) }

    private func writeNotebook(_ agent: String, lines: Int) throws {
        let url = home.appendingPathComponent(".claude/agent-memory/\(agent)/MEMORY.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "- a note\n", count: lines).write(to: url, atomically: true, encoding: .utf8)
    }

    private func editCharter(_ role: CrewRole, _ change: (String) -> String) throws {
        let url = installer.charterURL(for: role)
        try change(String(contentsOf: url, encoding: .utf8)).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func aFreshlyHiredMemberNeedsNothing() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        let report = keeper.check(crew, now: day(0))
        #expect(report.attention.isEmpty)
        #expect(report.notes["release-reviewer"] == CrewNote(displayName: "Bram", face: "bram"))
        #expect(keeper.history.versions("release-reviewer", .charter).count == 1)
        #expect(keeper.changes(for: "release-reviewer").isEmpty)
    }

    @Test func anOutsideEditIsFlaggedUntilAcceptedOrPutBack() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        _ = keeper.check(crew, now: day(0))

        try editCharter(.bram) { $0 + "\n6. Be lenient on Fridays.\n" }
        let edited = keeper.check(crew, now: day(1))
        #expect(edited.attention.map(\.kind) == [.charterEdited])
        #expect(edited.attention.first?.displayName == "Bram")
        #expect(edited.notes["release-reviewer"]?.hasUnseenChanges == true)

        let change = try #require(keeper.changes(for: "release-reviewer").first)
        #expect(change.kind == .charter)
        #expect(change.since == day(0))
        #expect(change.lines.filter { $0.kind == .added }.map(\.text).contains("6. Be lenient on Fridays."))

        try installer.acceptCharter(agentNamed: "release-reviewer")
        #expect(keeper.check(crew, now: day(2)).attention.isEmpty)

        try editCharter(.bram) { $0 + "7. Another rule.\n" }
        #expect(keeper.check(crew, now: day(3)).attention.map(\.kind) == [.charterEdited])
        try installer.restoreCharter(agentNamed: "release-reviewer")
        #expect(keeper.check(crew, now: day(4)).attention.isEmpty)
        #expect(try String(contentsOf: installer.charterURL(for: .bram), encoding: .utf8).contains("6. Be lenient on Fridays."))
        #expect(try !String(contentsOf: installer.charterURL(for: .bram), encoding: .utf8).contains("7. Another rule."))
    }

    @Test func aMissingGuardOutranksAnEditAndCanBePutBack() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        try installer.hire(.wren, model: .opus)
        _ = keeper.check(crew, now: day(0))

        try editCharter(.wren) { $0 + "\nOne more rule.\n" }
        try editCharter(.bram) { text in
            let start = text.range(of: "hooks:")!.lowerBound
            let end = text.range(of: "\n---\n", range: start..<text.endIndex)!.lowerBound
            return String(text[..<start]) + "note: no hooks" + String(text[end...])
        }
        let report = keeper.check(crew, now: day(1))
        #expect(report.attention.map(\.kind) == [.guardMissing, .charterEdited])
        #expect(report.attention.map(\.displayName) == ["Bram", "Wren"])

        try installer.restoreCharter(agentNamed: "release-reviewer")
        #expect(keeper.check(crew, now: day(2)).attention.map(\.displayName) == ["Wren"])
    }

    @Test func aGuardPointedAtAnotherMemberDoesNotCount() throws {
        let charter = installer.charter(for: .bram, model: .opus)
        #expect(CrewInstaller.hasGuard(charter, agent: "release-reviewer"))
        #expect(!CrewInstaller.hasGuard(charter, agent: "security-reviewer"))
        #expect(!CrewInstaller.hasGuard(charter.replacingOccurrences(of: "PreToolUse", with: "PostToolUse"), agent: "release-reviewer"))
        #expect(!CrewInstaller.hasGuard(charter.replacingOccurrences(of: "Write|Edit|MultiEdit|NotebookEdit|Bash", with: "Read"), agent: "release-reviewer"))
        // The matcher must be exactly the one written: no tool may drop out of it.
        for narrower in ["Write|Bash", "Write|Edit|Bash", "Write|Edit|MultiEdit|Bash", "Bash|Write|Edit|MultiEdit|NotebookEdit"] {
            #expect(!CrewInstaller.hasGuard(charter.replacingOccurrences(of: CrewInstaller.guardMatcher, with: narrower), agent: "release-reviewer"), "\(narrower)")
        }
        #expect(CrewInstaller.hasGuard(charter.replacingOccurrences(of: "\"\(CrewInstaller.guardMatcher)\"", with: "'\(CrewInstaller.guardMatcher)'"), agent: "release-reviewer"))
        // A full matcher elsewhere does not cover a guard that sits under a narrower one.
        let split = charter.replacingOccurrences(of: "    - matcher: \"\(CrewInstaller.guardMatcher)\"",
                                                 with: "    - matcher: \"\(CrewInstaller.guardMatcher)\"\n      hooks: []\n    - matcher: \"Write\"")
        #expect(split != charter)
        #expect(!CrewInstaller.hasGuard(split, agent: "release-reviewer"))
        // A narrowed PreToolUse doesn't count because a later event carries the full matcher and the guard.
        let narrowed = charter.replacingOccurrences(of: "  PreToolUse:\n    - matcher: \"\(CrewInstaller.guardMatcher)\"", with: "  PreToolUse:\n    - matcher: \"Write\"")
        let laterEvent = narrowed.replacingOccurrences(of: "\n---\n", with: "\n  PostToolUse:\n    - matcher: \"\(CrewInstaller.guardMatcher)\"\n      hooks:\n        - type: command\n          command: \"'\(installer.guardURL.path)' release-reviewer\"\n---\n")
        #expect(narrowed != charter && laterEvent != narrowed)
        #expect(!CrewInstaller.hasGuard(laterEvent, agent: "release-reviewer"))
        // A guard that is commented out runs nothing.
        let commented = charter.replacingOccurrences(of: "          command: ", with: "          # command: ")
        #expect(commented != charter)
        #expect(!CrewInstaller.hasGuard(commented, agent: "release-reviewer"))
        // A comment inside the block is fine.
        #expect(CrewInstaller.hasGuard(charter.replacingOccurrences(of: "  PreToolUse:\n", with: "  PreToolUse:\n  # every tool that writes or runs\n"), agent: "release-reviewer"))
        // Mentioning the guard in the instructions is not the same as running it.
        let prose = "---\nname: release-reviewer\n---\nhooks: PreToolUse: guard.sh' release-reviewer\" Write Bash\n"
        #expect(!CrewInstaller.hasGuard(prose, agent: "release-reviewer"))
    }

    @Test func agentsThePersonWroteAreRecordedButNeverFlagged() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".claude/agents/mine.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: mine\ndescription: my own\n---\nv1\n".write(to: url, atomically: true, encoding: .utf8)
        _ = keeper.check(crew, now: day(0))
        try "---\nname: mine\ndescription: my own\n---\nv2\n".write(to: url, atomically: true, encoding: .utf8)
        let report = keeper.check(crew, now: day(1))
        #expect(report.attention.isEmpty)
        #expect(report.notes["mine"]?.hasUnseenChanges == true)
        #expect(keeper.history.versions("mine", .charter).count == 2)
    }

    @Test func notebookGrowthIsMeasuredOverTheWeekAndFullnessFlagged() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        try writeNotebook("release-reviewer", lines: 10)
        #expect(keeper.check(crew, now: day(0)).notes["release-reviewer"]?.notebookGrowth == nil)

        try writeNotebook("release-reviewer", lines: 14)
        #expect(keeper.check(crew, now: day(3)).notes["release-reviewer"]?.notebookGrowth == 4)

        try writeNotebook("release-reviewer", lines: 20)
        // Day 12: the day-3 version is now the newest one at least a week old.
        #expect(keeper.check(crew, now: day(12)).notes["release-reviewer"]?.notebookGrowth == 6)

        try writeNotebook("release-reviewer", lines: 185)
        let full = keeper.check(crew, now: day(13))
        #expect(full.attention.map(\.kind) == [.notebookFull])
        #expect(full.attention.first?.title == "Bram's notebook is nearly full")
    }

    @Test func lookingClearsUnseenAndMovesTheBaseline() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        try writeNotebook("release-reviewer", lines: 2)
        _ = keeper.check(crew, now: day(0))
        try writeNotebook("release-reviewer", lines: 5)
        #expect(keeper.check(crew, now: day(1)).notes["release-reviewer"]?.hasUnseenChanges == true)
        #expect(LineDiff.counts(try #require(keeper.changes(for: "release-reviewer").first).lines) == (3, 0))

        keeper.markSeen("release-reviewer")
        #expect(keeper.check(crew, now: day(1)).notes["release-reviewer"]?.hasUnseenChanges == false)
        #expect(keeper.changes(for: "release-reviewer").isEmpty)

        try writeNotebook("release-reviewer", lines: 6)
        _ = keeper.check(crew, now: day(2))
        let next = try #require(keeper.changes(for: "release-reviewer").first)
        #expect(next.since == day(1))
        #expect(LineDiff.counts(next.lines) == (1, 0))
    }

    @Test func eachCauseIsAnnouncedOnceAndTheDotClearsWhenNoticed() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        _ = keeper.check(crew, now: day(0))
        try editCharter(.bram) { $0 + "\nRule A.\n" }
        let first = keeper.check(crew, now: day(1)).attention

        #expect(keeper.takeUnannounced(first).count == 1)
        #expect(keeper.takeUnannounced(first).isEmpty)
        #expect(keeper.unnoticed(first).count == 1)
        keeper.markNoticed(first)
        #expect(keeper.unnoticed(first).isEmpty)

        // A second, different edit is a new cause: announced and dotted again.
        try editCharter(.bram) { $0 + "Rule B.\n" }
        let second = keeper.check(crew, now: day(2)).attention
        #expect(second.first?.id != first.first?.id)
        #expect(keeper.takeUnannounced(second).count == 1)
        #expect(keeper.unnoticed(second).count == 1)

        // Once resolved, the same edit made again later is announced again.
        try installer.restoreCharter(agentNamed: "release-reviewer")
        #expect(keeper.takeUnannounced(keeper.check(crew, now: day(3)).attention).isEmpty)
        try editCharter(.bram) { $0 + "\nRule A.\nRule B.\n" }
        #expect(keeper.takeUnannounced(keeper.check(crew, now: day(4)).attention).count == 1)
    }

    @Test func aMemberHiredBeforeCopiesWereKeptStartsFromTheCharterAsFound() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        try FileManager.default.removeItem(at: installer.writtenURL(agentNamed: "release-reviewer"))
        #expect(keeper.check(crew, now: day(0)).attention.isEmpty)
        #expect(installer.writtenHash(agentNamed: "release-reviewer") != nil)
        try editCharter(.bram) { $0 + "\nNew rule.\n" }
        #expect(keeper.check(crew, now: day(1)).attention.map(\.kind) == [.charterEdited])
    }

    @Test func removingAMemberForgetsTheCharterOfRecord() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try installer.hire(.bram, model: .opus)
        try installer.remove(agentNamed: "release-reviewer")
        #expect(installer.writtenHash(agentNamed: "release-reviewer") == nil)
        #expect(keeper.check(crew, now: day(0)).attention.isEmpty)
    }
}

@MainActor
struct TeamMonitorWorkingTests {
    @Test func aMemberIsWorkingUntilItsRunGoesQuiet() {
        let monitor = TeamMonitor(scan: { TeamSnapshot(scannedAt: $0, members: []) })
        monitor.sawActivity(agent: "release-reviewer", at: start)
        monitor.sawActivity(agent: "security-reviewer", at: start.addingTimeInterval(10))
        #expect(monitor.working == ["release-reviewer", "security-reviewer"])

        monitor.updateWorking(at: start.addingTimeInterval(TeamMonitor.workingWindow + 1))
        #expect(monitor.working == ["security-reviewer"])
        monitor.updateWorking(at: start.addingTimeInterval(TeamMonitor.workingWindow + 11))
        #expect(monitor.working.isEmpty)
    }
}

@MainActor
struct CrewWatcherTests {
    @Test func classifiesOnlyCrewFilesAndSubagentTranscripts() {
        let home = "/Users/me/.claude"
        #expect(CrewWatcher.classify("\(home)/agents/release-reviewer.md") == .crewFile)
        #expect(CrewWatcher.classify("\(home)/agent-memory/release-reviewer/MEMORY.md") == .crewFile)
        #expect(CrewWatcher.classify("\(home)/agent-memory/release-reviewer/topics/notes.md") == .crewFile)
        #expect(CrewWatcher.classify("\(home)/agents/.release-reviewer.md.swp") == .other)
        #expect(CrewWatcher.classify("\(home)/projects/-Users-me-app/s1/subagents/agent-a1.jsonl") == .run)
        #expect(CrewWatcher.classify("\(home)/projects/-Users-me-app/s1/subagents/agent-a1.meta.json") == .other)
        #expect(CrewWatcher.classify("\(home)/projects/-Users-me-app/s1.jsonl") == .other)
        #expect(CrewWatcher.classify("\(home)/settings.json") == .other)
    }

    @Test func aRunByACrewMemberMarksThemWorkingAndOthersAreIgnored() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.bram, model: .opus)
        let claude = home.appendingPathComponent(".claude")
        let monitor = TeamMonitor(claudeDirectory: claude, keeper: CrewKeeper(installer: installer))
        await monitor.checkCrew()

        let runs = claude.appendingPathComponent("projects/-p/s1/subagents")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try #"{"agentType":"release-reviewer"}"#.write(to: runs.appendingPathComponent("agent-a.meta.json"), atomically: true, encoding: .utf8)
        try #"{"agentType":"Explore"}"#.write(to: runs.appendingPathComponent("agent-b.meta.json"), atomically: true, encoding: .utf8)

        let watcher = CrewWatcher(home: home, monitor: monitor)
        watcher.filesChanged([runs.appendingPathComponent("agent-b.jsonl").path, runs.appendingPathComponent("agent-missing.jsonl").path], now: start)
        #expect(monitor.working.isEmpty)
        watcher.filesChanged([runs.appendingPathComponent("agent-a.jsonl").path], now: start)
        #expect(monitor.working == ["release-reviewer"])
        watcher.stop()
    }

    /// The real thing: a file saved on disk reaches the monitor through FSEvents, with no call from the test.
    @Test func anEditOnDiskIsNoticedWithoutBeingTold() async throws {
        let home = try tempHome().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.bram, model: .opus)
        let monitor = TeamMonitor(claudeDirectory: home.appendingPathComponent(".claude"), keeper: CrewKeeper(installer: installer))
        await monitor.checkCrew()
        let watcher = CrewWatcher(home: home, monitor: monitor)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let url = installer.charterURL(for: .bram)
        try (String(contentsOf: url, encoding: .utf8) + "\nBe lenient.\n").write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<100 where monitor.report.attention.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(monitor.report.attention.map(\.kind) == [.charterEdited])
    }

    @Test func aCheckFindsAnOutsideEditAndAnnouncesItOnce() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.bram, model: .opus)
        let monitor = TeamMonitor(claudeDirectory: home.appendingPathComponent(".claude"), keeper: CrewKeeper(installer: installer))
        var announced: [[CrewAttention]] = []
        monitor.onNewAttention = { announced.append($0) }
        await monitor.checkCrew()
        #expect(announced.isEmpty)

        let url = installer.charterURL(for: .bram)
        try (String(contentsOf: url, encoding: .utf8) + "\nBe lenient.\n").write(to: url, atomically: true, encoding: .utf8)
        await monitor.checkCrew()
        await monitor.checkCrew()
        #expect(announced.count == 1)
        #expect(announced.first?.first?.title == "Bram's charter was edited")
        #expect(monitor.unnoticed.count == 1)

        monitor.markNoticed()
        #expect(monitor.unnoticed.isEmpty)
        await monitor.checkCrew()
        #expect(monitor.unnoticed.isEmpty)
        #expect(monitor.report.attention.count == 1)

        await monitor.restoreCharter("release-reviewer")
        #expect(monitor.report.attention.isEmpty)
    }
}

@MainActor
struct CrewMenuBarGlyphTests {
    @Test func theDotIsSmallAndSaysHowManyNeedYou() {
        let one = CrewMenuBarGlyph.dot(count: 1)
        #expect(one.size == NSSize(width: 7, height: 7))
        #expect(one.accessibilityDescription == "A crew member needs your attention")
        #expect(CrewMenuBarGlyph.dot(count: 3).accessibilityDescription == "3 crew members need your attention")
    }
}
