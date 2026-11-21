import Foundation
import Testing
@testable import LobsterOne

/// Fixed clock and calendar: Friday 20 November 2026, UTC, weeks starting Monday.
private enum Clock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A moment in November 2026.
    static func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date { on(2026, 11, day, hour, minute) }

    static func on(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

private func job(_ repeats: CrewJob.Repeats, first: Date, agent: String = "security-reviewer") -> CrewJob {
    CrewJob(agent: agent, task: "Review what merged to main", folder: "/tmp/app", repeats: repeats, first: first)
}

struct CrewJobTests {
    @Test func aWeekdayJobSkipsTheWeekend() {
        let wren = job(.weekdays, first: Clock.at(16, 17, 30))
        let days = wren.occurrences(from: Clock.at(16), to: Clock.at(22, 23, 59), calendar: Clock.calendar)
        #expect(days.map { Clock.calendar.component(.day, from: $0) } == [16, 17, 18, 19, 20])
        #expect(days.allSatisfy { Clock.calendar.component(.hour, from: $0) == 17 && Clock.calendar.component(.minute, from: $0) == 30 })
    }

    @Test func nothingIsDueBeforeTheJobsFirstTime() {
        let wren = job(.daily, first: Clock.at(18, 17, 30))
        let days = wren.occurrences(from: Clock.at(16), to: Clock.at(19, 23, 59), calendar: Clock.calendar)
        #expect(days == [Clock.at(18, 17, 30), Clock.at(19, 17, 30)])
        // The first day itself does not count before its time.
        #expect(wren.occurrences(from: Clock.at(18), to: Clock.at(18, 17, 29), calendar: Clock.calendar).isEmpty)
    }

    @Test func aWeeklyJobKeepsItsWeekdayAndAOneOffHappensOnce() {
        let edda = job(.weekly, first: Clock.at(16, 9))  // a Monday
        #expect(edda.occurrences(from: Clock.at(16), to: Clock.at(30, 23), calendar: Clock.calendar)
            == [Clock.at(16, 9), Clock.at(23, 9), Clock.at(30, 9)])
        let once = job(.once, first: Clock.at(20, 16))
        #expect(once.occurrences(from: Clock.at(1), to: Clock.at(30, 23), calendar: Clock.calendar) == [Clock.at(20, 16)])
        #expect(once.next(after: Clock.at(20, 16), calendar: Clock.calendar) == nil)
    }

    @Test func aMonthlyJobSetForThe31stRunsOnAShorterMonthsLastDay() {
        let ivy = job(.monthly, first: Clock.on(2026, 10, 31, 10))
        let days = ivy.occurrences(from: Clock.on(2026, 10, 1), to: Clock.on(2027, 2, 28, 23), calendar: Clock.calendar)
        #expect(days == [Clock.on(2026, 10, 31, 10), Clock.on(2026, 11, 30, 10), Clock.on(2026, 12, 31, 10),
                         Clock.on(2027, 1, 31, 10), Clock.on(2027, 2, 28, 10)])
    }

    @Test func theScheduleReadsInPlainWords() {
        #expect(job(.weekdays, first: Clock.at(16, 17, 30)).schedule(calendar: Clock.calendar) == "Every weekday at 17:30")
        #expect(job(.weekly, first: Clock.at(16, 9)).schedule(calendar: Clock.calendar) == "Every Monday at 09:00")
        #expect(job(.once, first: Clock.at(20, 16)).schedule(calendar: Clock.calendar) == "On 20 November at 16:00")
        #expect(job(.monthly, first: Clock.at(2, 10)).schedule(calendar: Clock.calendar) == "On day 2 of every month at 10:00")
        #expect(job(.weekdays, first: Clock.at(20, 9)).next(after: Clock.at(20, 18), calendar: Clock.calendar) == Clock.at(23, 9))
    }
}

struct CrewCalendarLogicTests {
    @Test func aJobIsDueOnceItsTimeHasComeTodayAndOnlyUntilThePersonIsTold() {
        let wren = job(.weekdays, first: Clock.at(16, 17, 30))
        var file = CrewCalendarFile(jobs: [wren])
        #expect(CrewCalendar.newlyDue(file, now: Clock.at(20, 17, 29), calendar: Clock.calendar).isEmpty)
        let due = CrewCalendar.newlyDue(file, now: Clock.at(20, 17, 31), calendar: Clock.calendar)
        // Monday to Thursday went by with the Mac asleep; only today's is raised.
        #expect(due.map(\.due) == [Clock.at(20, 17, 30)])
        file.runs = [CrewRun(job: wren.id, due: Clock.at(20, 17, 30), state: .waiting)]
        #expect(CrewCalendar.newlyDue(file, now: Clock.at(20, 18), calendar: Clock.calendar).isEmpty)
    }

    @Test func aPausedJobIsNeverDueAndShowsNothingAhead() {
        var wren = job(.weekdays, first: Clock.at(16, 17, 30))
        wren.paused = true
        let file = CrewCalendarFile(jobs: [wren], runs: [CrewRun(job: wren.id, due: Clock.at(17, 17, 30), state: .done, findings: 2)])
        #expect(CrewCalendar.newlyDue(file, now: Clock.at(20, 18), calendar: Clock.calendar).isEmpty)
        let week = CrewCalendar.week(file, containing: Clock.at(20), now: Clock.at(20, 12), calendar: Clock.calendar)
        // The past stays on the calendar, with what came of it; today and after are blank.
        #expect(week[1].entries.map(\.status) == [.done(findings: 2)])
        #expect(week[0].entries.map(\.status) == [.missed])
        #expect(week[4].entries.isEmpty)
        #expect(CrewCalendar.comingUp(file, now: Clock.at(20, 12), calendar: Clock.calendar).isEmpty)
    }

    @Test func theWeekStartsOnMondayAndSaysWhatBecameOfEachJob() {
        let wren = job(.weekdays, first: Clock.at(16, 17, 30))
        let edda = job(.weekly, first: Clock.at(16, 9), agent: "data-analyst")
        let file = CrewCalendarFile(jobs: [wren, edda], runs: [
            CrewRun(job: edda.id, due: Clock.at(16, 9), state: .done),
            CrewRun(job: wren.id, due: Clock.at(16, 17, 30), state: .done, findings: 0),
            CrewRun(job: wren.id, due: Clock.at(17, 17, 30), state: .failed, note: "It ran past the time allowed."),
            CrewRun(job: wren.id, due: Clock.at(18, 17, 30), state: .waiting),
            CrewRun(job: wren.id, due: Clock.at(20, 17, 30), state: .waiting),
        ])
        let week = CrewCalendar.week(file, containing: Clock.at(20), now: Clock.at(20, 18), calendar: Clock.calendar)
        #expect(week.count == 7)
        #expect(week.map { Clock.calendar.component(.day, from: $0.date) } == [16, 17, 18, 19, 20, 21, 22])
        #expect(week[0].entries.map(\.job.agent) == ["data-analyst", "security-reviewer"])
        #expect(week[0].entries.map(\.status) == [.done(findings: nil), .done(findings: 0)])
        #expect(week[1].entries.map(\.status) == [.failed("It ran past the time allowed.")])
        // Told on Wednesday and never started: a day later that is simply not run.
        #expect(week[2].entries.map(\.status) == [.missed])
        #expect(week[3].entries.map(\.status) == [.missed])
        #expect(week[4].entries.map(\.status) == [.due])
        #expect(week[5].entries.isEmpty && week[6].entries.isEmpty)
    }

    @Test func comingUpPutsWhatIsWaitingBeforeWhatIsNext() {
        let wren = job(.weekdays, first: Clock.at(16, 17, 30))
        let edda = job(.weekly, first: Clock.at(16, 9), agent: "data-analyst")
        let file = CrewCalendarFile(jobs: [edda, wren], runs: [CrewRun(job: wren.id, due: Clock.at(20, 17, 30), state: .waiting)])
        let next = CrewCalendar.comingUp(file, now: Clock.at(20, 18), calendar: Clock.calendar)
        #expect(next.map(\.due) == [Clock.at(20, 17, 30), Clock.at(23, 9), Clock.at(23, 17, 30)])
        #expect(next.map(\.status) == [.due, .upcoming, .upcoming])
    }
}

struct CrewCalendarStoreTests {
    @Test func theCalendarComesBackAsItWasSavedAndOldRunsAreDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CrewCalendarStore(supportDirectory: dir)
        #expect(store.load() == CrewCalendarFile())
        let wren = job(.weekdays, first: Clock.at(16, 17, 30))
        let runs = (0..<650).map { CrewRun(job: wren.id, due: Clock.on(2025, 1, 1).addingTimeInterval(Double($0) * 86_400), state: .done, findings: $0) }
        try store.save(CrewCalendarFile(jobs: [wren], runs: runs))
        // A calendar saved before jobs could ask first still reads, and its jobs start by themselves.
        #expect(try #require(String(data: Data(contentsOf: dir.appendingPathComponent("Calendar/calendar.json")), encoding: .utf8)).contains("asksFirst") == false)
        let back = store.load()
        #expect(back.jobs == [wren])
        #expect(back.runs.count == 600 && back.runs.first?.findings == 50 && back.runs.last?.findings == 649)
        store.saveReport("All clear.", for: runs[649])
        #expect(store.report(for: runs[649]) == "All clear.")
        #expect(store.report(for: runs[0]) == nil)
    }
}

@MainActor
struct CrewCalendarMonitorTests {
    private func monitor(now: @escaping () -> Date, outcome: CrewJobRunner.Outcome = .init(state: .done, findings: 2, report: "Two things."))
        -> (CrewCalendarMonitor, CrewCalendarStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID().uuidString)")
        let store = CrewCalendarStore(supportDirectory: dir)
        return (CrewCalendarMonitor(store: store, calendar: Clock.calendar, now: now, run: { _ in outcome }), store, dir)
    }

    @Test func aJobStartsByItselfWhenItsTimeComesAndSaysWhatCameOfIt() async {
        var time = Clock.at(20, 17, 0)
        let (monitor, store, dir) = monitor(now: { time })
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked = 0
        var finished: [CrewRun] = []
        monitor.onDue = { asked += $0.count }
        monitor.onFinished = { _, run in finished.append(run) }
        let wren = job(.weekdays, first: Clock.at(20, 17, 30))
        let edda = job(.daily, first: Clock.at(20, 17, 30), agent: "data-analyst")
        #expect(wren.startsItself)
        monitor.start()
        monitor.save(wren)
        monitor.save(edda)
        #expect(monitor.selfStarted == nil)
        time = Clock.at(20, 17, 31)
        monitor.tick()
        monitor.tick()
        await monitor.selfStarted?.value
        // Both ran, once each, with nobody asked and nobody clicking.
        #expect(asked == 0)
        #expect(finished.map(\.state) == [.done, .done])
        #expect(monitor.file.runs.map(\.state) == [.done, .done])
        #expect(store.load().runs.count == 2)
        #expect(CrewJobNotifier.outcome(finished[0], name: "Wren") == ("Wren is done", "2 findings."))
    }

    @Test func outcomesReadPlainly() {
        let id = UUID()
        func run(_ state: CrewRun.State, _ findings: Int?, _ note: String? = nil) -> CrewRun {
            CrewRun(job: id, due: Clock.at(20, 9), state: state, findings: findings, note: note)
        }
        #expect(CrewJobNotifier.outcome(run(.done, 0), name: "Wren").detail == "Nothing found.")
        #expect(CrewJobNotifier.outcome(run(.done, 1), name: "Wren").detail == "1 finding.")
        #expect(CrewJobNotifier.outcome(run(.done, nil), name: "Edda").detail == "The report is on the calendar.")
        #expect(CrewJobNotifier.outcome(run(.failed, nil, "It ran past the time allowed."), name: "Wren")
            == ("Wren did not finish", "It ran past the time allowed."))
    }

    @Test func aJobThatAsksFirstIsAnnouncedOnceAndRunsOnlyWhenAsked() async {
        var time = Clock.at(20, 17, 0)
        let (monitor, store, dir) = monitor(now: { time })
        defer { try? FileManager.default.removeItem(at: dir) }
        var announced: [Date] = []
        monitor.onDue = { announced += $0.map(\.due) }
        var wren = job(.weekdays, first: Clock.at(20, 17, 30))
        wren.asksFirst = true
        monitor.start()
        monitor.save(wren)
        #expect(announced.isEmpty)
        time = Clock.at(20, 17, 31)
        monitor.tick()
        monitor.tick()
        #expect(announced == [Clock.at(20, 17, 30)])
        // Told, not started: nothing has run.
        #expect(monitor.file.runs.map(\.state) == [.waiting])
        #expect(monitor.week(containing: time)[4].entries.map(\.status) == [.due])

        await monitor.run(key: CrewRun.key(job: wren.id, due: Clock.at(20, 17, 30)))
        #expect(monitor.file.runs.map(\.state) == [.done])
        #expect(monitor.week(containing: time)[4].entries.map(\.status) == [.done(findings: 2)])
        #expect(monitor.report(for: monitor.week(containing: time)[4].entries[0]) == "Two things.")
        #expect(monitor.recent(wren) == "Last 7 days: 1 run, 2 findings.")
        // And it is on disk for the next launch.
        #expect(store.load().runs.map(\.state) == [.done])
    }

    @Test func aFailedRunSaysWhyAndARunCutShortByQuittingIsNotLeftRunning() async throws {
        let time = Clock.at(20, 18)
        let failure = CrewJobRunner.Outcome(state: .failed, note: "The folder /tmp/app is not there any more.", report: "")
        let (monitor, store, dir) = monitor(now: { time }, outcome: failure)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wren = job(.weekdays, first: Clock.at(20, 17, 30))
        monitor.start()
        monitor.save(wren)
        await monitor.run(wren, due: Clock.at(20, 17, 30))
        #expect(monitor.week(containing: time)[4].entries.map(\.status) == [.failed("The folder /tmp/app is not there any more.")])

        try store.save(CrewCalendarFile(jobs: [wren], runs: [CrewRun(job: wren.id, due: Clock.at(20, 17, 30), state: .running)]))
        monitor.start()
        #expect(monitor.file.runs.map(\.state) == [.failed])
        #expect(monitor.file.runs.first?.note == "LobsterOne quit while it was running.")
    }

    @Test func deletingAJobTakesItsRunsAndPausingStopsReminders() {
        var time = Clock.at(20, 12)
        let (monitor, _, dir) = monitor(now: { time })
        defer { try? FileManager.default.removeItem(at: dir) }
        var announced = 0
        monitor.onDue = { announced += $0.count }
        var wren = job(.weekdays, first: Clock.at(20, 17, 30))
        wren.asksFirst = true
        monitor.start()
        monitor.save(wren)
        monitor.setPaused(true, job: wren.id)
        time = Clock.at(20, 18)
        monitor.tick()
        #expect(announced == 0)
        monitor.setPaused(false, job: wren.id)
        monitor.tick()
        #expect(announced == 1)
        monitor.delete(wren.id)
        #expect(monitor.file == CrewCalendarFile())
    }
}

struct CrewJobRunnerTests {
    @Test func aJobIsRefusedWithAReasonBeforeAnythingIsStarted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = CrewJobRunner(homeDirectory: home)
        let wren = job(.daily, first: Clock.at(20, 9))
        #expect(await runner.run(wren, claudePath: nil).note == "Claude Code was not found on this Mac.")
        // Nobody by that name has been hired here.
        #expect(await runner.run(wren, claudePath: "/usr/bin/true").note == "Wren is no longer on the crew.")
        try CrewInstaller(homeDirectory: home, supportDirectory: home.appendingPathComponent("support")).hire(.wren, model: .opus)
        var gone = wren
        gone.folder = home.appendingPathComponent("no-such-folder").path
        let outcome = await runner.run(gone, claudePath: "/usr/bin/true")
        #expect(outcome.state == .failed && outcome.note?.hasSuffix("is not there any more.") == true)
    }

    @Test func aRunCountsTheFindingsItAddedToTheLedger() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try CrewInstaller(homeDirectory: home, supportDirectory: home.appendingPathComponent("support")).hire(.wren, model: .opus)
        let notebook = home.appendingPathComponent(".claude/agent-memory/security-reviewer")
        try FileManager.default.createDirectory(at: notebook, withIntermediateDirectories: true)
        let ledger = notebook.appendingPathComponent("ledger.md")
        try "- [kept] 2026-11-19 | app | A.swift:1 | An old one.\n".write(to: ledger, atomically: true, encoding: .utf8)
        // Stands in for Claude Code: answers on standard output and adds two findings to the ledger.
        let fake = home.appendingPathComponent("claude")
        try """
        #!/bin/sh
        cat > /dev/null
        printf '%s\\n' '- [open] 2026-11-20 | app | B.swift:2 | First.' '- [open] 2026-11-20 | app | C.swift:3 | Second.' >> '\(ledger.path)'
        echo "Two findings in $(basename "$PWD")."
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var wren = job(.daily, first: Clock.at(20, 9))
        wren.folder = home.path
        let outcome = await CrewJobRunner(homeDirectory: home).run(wren, claudePath: fake.path)
        #expect(outcome.state == .done && outcome.findings == 2)
        #expect(outcome.report.trimmingCharacters(in: .whitespacesAndNewlines) == "Two findings in \(home.lastPathComponent).")
        #expect(CrewJobRunner.arguments(agent: "security-reviewer").contains("--agent"))
    }
}

struct CrewJobFoldersTests {
    @Test func aJobIsDoneInEachOfItsFoldersAndOneBadFolderDoesNotStopTheRest() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try CrewInstaller(homeDirectory: home, supportDirectory: home.appendingPathComponent("support")).hire(.wren, model: .opus)
        let notebook = home.appendingPathComponent(".claude/agent-memory/security-reviewer")
        let ledger = notebook.appendingPathComponent("ledger.md")
        for name in ["app", "site"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: notebook, withIntermediateDirectories: true)
        try "".write(to: ledger, atomically: true, encoding: .utf8)
        // Stands in for Claude Code: one finding per folder, and says where it ran.
        let fake = home.appendingPathComponent("claude")
        try """
        #!/bin/sh
        cat > /dev/null
        echo "- [open] 2026-11-20 | $(basename "$PWD") | A.swift:1 | Something." >> '\(ledger.path)'
        echo "Looked at $(basename "$PWD")."
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var wren = job(.daily, first: Clock.at(20, 9))
        wren.folders = [home.appendingPathComponent("app").path, home.appendingPathComponent("site").path]
        let both = await CrewJobRunner(homeDirectory: home).run(wren, claudePath: fake.path)
        #expect(both.state == .done && both.findings == 2)
        #expect(both.report == "## app\n\nLooked at app.\n\n## site\n\nLooked at site.")

        wren.folders = [home.appendingPathComponent("gone").path, home.appendingPathComponent("site").path]
        let partly = await CrewJobRunner(homeDirectory: home).run(wren, claudePath: fake.path)
        #expect(partly.state == .failed && partly.findings == 1)
        #expect(partly.note?.hasSuffix("gone is not there any more.") == true)
        #expect(partly.report == "## site\n\nLooked at site.")
    }

    @Test func foldersReadBackAsAListAndInPlainWords() throws {
        var wren = job(.daily, first: Clock.at(20, 9))
        #expect(wren.folders == ["/tmp/app"] && wren.otherFolders == nil && wren.places == "app")
        wren.folders = ["/p/App", "/p/Site"]
        #expect(wren.folder == "/p/App" && wren.places == "App and Site")
        wren.folders = ["/p/App", "/p/Site", "/p/Docs", "/p/Game"]
        #expect(wren.places == "App, Site and 2 more")
        #expect(CrewJobNotifier.body(wren) == "Review what merged to main. In App, Site and 2 more.")
        // A calendar saved when a job had one folder still reads.
        let old = #"{"id":"\#(wren.id.uuidString)","agent":"linter","task":"t","folder":"/p/App","repeats":"daily","first":0,"paused":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let read = try decoder.decode(CrewJob.self, from: Data(old.utf8))
        #expect(read.folders == ["/p/App"] && read.startsItself)
    }
}

struct CrewJobNotifierTests {
    @Test func theReminderSaysWhatAndWhere() {
        var wren = job(.daily, first: Clock.at(20, 9))
        wren.folder = "/Users/me/Projects/Robocog---Mac"
        #expect(CrewJobNotifier.body(wren) == "Review what merged to main. In Robocog---Mac.")
        wren.task = String(repeating: "long ", count: 40)
        #expect(CrewJobNotifier.body(wren).count < 150)
        #expect(CrewJobNotifier.category.actions.map(\.title) == ["Run now", "Later"])
    }
}
