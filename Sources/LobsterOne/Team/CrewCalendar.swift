import Foundation

/// Something a crew member does at a set time: who, what, in which folder, and when.
nonisolated struct CrewJob: Identifiable, Codable, Equatable, Sendable {
    enum Repeats: String, Codable, CaseIterable, Sendable {
        case once, daily, weekdays, weekly, monthly

        var label: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
    }

    var id = UUID()
    /// The crew member's agent name, as in the charter.
    var agent: String
    /// What to ask, in the person's own words.
    var task: String
    /// The project folder the job runs in; the first, when there are several.
    var folder: String
    /// Further folders the same job is done in, one after another. Optional so calendars saved
    /// with a single folder still read.
    var otherFolders: [String]?

    /// Every folder the job is done in, in order.
    var folders: [String] {
        get { ([folder] + (otherFolders ?? [])).filter { !$0.isEmpty } }
        set {
            folder = newValue.first ?? ""
            otherFolders = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// "Robocog---Mac", "App and Site", "App, Site and 2 more".
    var places: String { Self.places(folders) }

    static func places(_ folders: [String]) -> String {
        let names = folders.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
    var repeats: Repeats
    /// The first time it is due. Carries the time of day, and for weekly and monthly jobs the
    /// weekday and the day of the month.
    var first: Date
    var paused = false
    /// True when the job waits for a click on its reminder. Nil or false: it starts on its own
    /// when its time comes. Optional so calendars saved before the choice existed still read.
    var asksFirst: Bool?

    var startsItself: Bool { asksFirst != true }

    /// Every time the job is due between two moments, both included, oldest first.
    func occurrences(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        guard end >= start, end >= first else { return [] }
        let time = calendar.dateComponents([.hour, .minute], from: first)
        var day = calendar.startOfDay(for: max(start, first))
        let lastDay = calendar.startOfDay(for: end)
        var found: [Date] = []
        // A year of days is more than any view asks for, and bounds a job set far in the past.
        var steps = 0
        while day <= lastDay, steps < 400 {
            if falls(on: day, calendar: calendar),
               let moment = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day),
               moment >= start, moment <= end, moment >= first {
                found.append(moment)
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = following
            steps += 1
        }
        return found
    }

    /// The next time it is due after a moment; nil for a job that has had its one day.
    func next(after moment: Date, calendar: Calendar) -> Date? {
        guard let horizon = calendar.date(byAdding: .day, value: 370, to: moment) else { return nil }
        return occurrences(from: moment.addingTimeInterval(1), to: horizon, calendar: calendar).first
    }

    private func falls(on day: Date, calendar: Calendar) -> Bool {
        switch repeats {
        case .once: return calendar.isDate(day, inSameDayAs: first)
        case .daily: return true
        case .weekdays: return !calendar.isDateInWeekend(day)
        case .weekly: return calendar.component(.weekday, from: day) == calendar.component(.weekday, from: first)
        case .monthly:
            // A job set for the 31st runs on the last day of a shorter month.
            let wanted = calendar.component(.day, from: first)
            let length = calendar.range(of: .day, in: .month, for: day)?.count ?? wanted
            return calendar.component(.day, from: day) == min(wanted, length)
        }
    }

    /// "Every weekday at 17:30", "Every Monday at 09:00", "On 3 December at 10:00".
    func schedule(calendar: Calendar) -> String {
        let time = Self.clock(first, calendar: calendar)
        switch repeats {
        case .once: return "On \(Self.format(first, "d MMMM", calendar)) at \(time)"
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Every weekday at \(time)"
        case .weekly: return "Every \(Self.format(first, "EEEE", calendar)) at \(time)"
        case .monthly: return "On day \(calendar.component(.day, from: first)) of every month at \(time)"
        }
    }

    static func clock(_ date: Date, calendar: Calendar) -> String { format(date, "HH:mm", calendar) }

    static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// What became of one time a job was due.
nonisolated struct CrewRun: Identifiable, Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// The person was told it is due and has not started it.
        case waiting
        case running, done, failed
    }

    var job: UUID
    var due: Date
    var state: State
    var started: Date?
    var finished: Date?
    /// Lines the member added to its ledger during the run; nil for a member that keeps none.
    var findings: Int?
    /// Why it failed, in a sentence.
    var note: String?

    var id: String { Self.key(job: job, due: due) }

    static func key(job: UUID, due: Date) -> String { "\(job.uuidString)@\(Int(due.timeIntervalSince1970))" }
}

/// Everything the calendar keeps on disk.
nonisolated struct CrewCalendarFile: Codable, Equatable, Sendable {
    var jobs: [CrewJob] = []
    var runs: [CrewRun] = []
}

/// The calendar's reading of jobs and runs: what is due, what a week looks like, what comes next.
nonisolated enum CrewCalendar {
    enum Status: Equatable, Sendable {
        case upcoming
        /// Due today and waiting for the person.
        case due
        case running
        case done(findings: Int?)
        case failed(String)
        /// Its day passed without a run.
        case missed
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let job: CrewJob
        let due: Date
        let status: Status
        var id: String { CrewRun.key(job: job.id, due: due) }
    }

    struct Day: Identifiable, Equatable, Sendable {
        let date: Date
        let entries: [Entry]
        var id: Date { date }
    }

    /// Jobs whose time has come today and that the person has not been told about yet.
    /// Earlier days are never chased: a Mac that was asleep does not wake to a pile of reminders.
    static func newlyDue(_ file: CrewCalendarFile, now: Date, calendar: Calendar) -> [(job: CrewJob, due: Date)] {
        let known = Set(file.runs.map(\.id))
        let today = calendar.startOfDay(for: now)
        return file.jobs.filter { !$0.paused }.flatMap { job in
            job.occurrences(from: today, to: now, calendar: calendar)
                .filter { !known.contains(CrewRun.key(job: job.id, due: $0)) }
                .map { (job, $0) }
        }
    }

    static func status(of job: CrewJob, due: Date, runs: [String: CrewRun], now: Date, calendar: Calendar) -> Status {
        if let run = runs[CrewRun.key(job: job.id, due: due)] {
            switch run.state {
            case .running: return .running
            case .done: return .done(findings: run.findings)
            case .failed: return .failed(run.note ?? "It did not finish.")
            case .waiting: return calendar.isDate(due, inSameDayAs: now) ? .due : .missed
            }
        }
        if due > now { return .upcoming }
        return calendar.isDate(due, inSameDayAs: now) ? .due : .missed
    }

    /// The seven days of the week that holds `date`, Monday first, each with its jobs in time order.
    /// A paused job keeps its past but shows nothing ahead.
    static func week(_ file: CrewCalendarFile, containing date: Date, now: Date, calendar: Calendar) -> [Day] {
        var monday = calendar
        monday.firstWeekday = 2
        guard let start = monday.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        let runs = Dictionary(file.runs.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let end = calendar.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1) else { return nil }
            let entries = file.jobs.flatMap { job in
                job.occurrences(from: day, to: end, calendar: calendar).compactMap { due -> Entry? in
                    let status = status(of: job, due: due, runs: runs, now: now, calendar: calendar)
                    if job.paused, status == .upcoming || status == .due { return nil }
                    return Entry(job: job, due: due, status: status)
                }
            }
            return Day(date: day, entries: entries.sorted { $0.due < $1.due })
        }
    }

    /// What is waiting today, then what is next for each job, soonest first.
    static func comingUp(_ file: CrewCalendarFile, now: Date, calendar: Calendar, limit: Int = 3) -> [Entry] {
        let runs = Dictionary(file.runs.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let today = calendar.startOfDay(for: now)
        var entries: [Entry] = []
        for job in file.jobs where !job.paused {
            for due in job.occurrences(from: today, to: now, calendar: calendar) {
                let status = status(of: job, due: due, runs: runs, now: now, calendar: calendar)
                if status == .due || status == .running { entries.append(Entry(job: job, due: due, status: status)) }
            }
            if let next = job.next(after: now, calendar: calendar) {
                entries.append(Entry(job: job, due: next, status: .upcoming))
            }
        }
        return Array(entries.sorted { $0.due < $1.due }.prefix(limit))
    }
}

/// Reads and writes the calendar file, and keeps each run's report.
nonisolated struct CrewCalendarStore: Sendable {
    let directory: URL

    init(supportDirectory: URL = CrewInstaller().supportDirectory) {
        directory = supportDirectory.appendingPathComponent("Calendar")
    }

    private var fileURL: URL { directory.appendingPathComponent("calendar.json") }

    func reportURL(for run: CrewRun) -> URL {
        directory.appendingPathComponent("Reports").appendingPathComponent("\(run.id).md")
    }

    func load() -> CrewCalendarFile {
        guard let data = try? Data(contentsOf: fileURL) else { return CrewCalendarFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(CrewCalendarFile.self, from: data)) ?? CrewCalendarFile()
    }

    /// Keeps the most recent runs only; a year of daily jobs is plenty to look back on.
    func save(_ file: CrewCalendarFile) throws {
        var trimmed = file
        trimmed.runs = Array(file.runs.sorted { $0.due < $1.due }.suffix(600))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trimmed).write(to: fileURL, options: .atomic)
    }

    func saveReport(_ text: String, for run: CrewRun) {
        let url = reportURL(for: run)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func report(for run: CrewRun) -> String? {
        try? String(contentsOf: reportURL(for: run), encoding: .utf8)
    }
}

/// Starts a job: one headless Claude Code run as the crew member, in the job's folder.
/// Called when a job the person set to start by itself comes due, or when they click Run.
nonisolated struct CrewJobRunner: Sendable {
    struct Outcome: Equatable, Sendable {
        var state: CrewRun.State
        var findings: Int?
        var note: String?
        var report: String
    }

    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var timeout: TimeInterval = 900

    /// Every tool any member may hold. A charter's own list narrows this to the member's tools, and
    /// its guard still decides what each call may do.
    static func arguments(agent: String) -> [String] {
        ["-p", "--no-session-persistence", "--agent", agent,
         "--allowedTools", "Read,Grep,Glob,Bash(git:*),Bash(ls:*),Write,Edit,WebSearch,WebFetch"]
    }

    func run(_ job: CrewJob, claudePath: String?) async -> Outcome {
        guard let claudePath else {
            return Outcome(state: .failed, note: "Claude Code was not found on this Mac.", report: "")
        }
        let charter = homeDirectory.appendingPathComponent(".claude/agents/\(job.agent).md")
        guard CrewInstaller.isOurs(charter) else {
            let name = CrewRole.ready.first { $0.id == job.agent }?.name ?? TeamScanner.title(job.agent)
            return Outcome(state: .failed, note: "\(name) is no longer on the crew.", report: "")
        }
        let folders = job.folders
        guard !folders.isEmpty else { return Outcome(state: .failed, note: "The job has no folder.", report: "") }
        // The same job in each folder, one after another. One folder that fails does not stop the rest.
        let before = ledgerCount(job.agent)
        var reports: [String] = []
        var failures: [String] = []
        for folder in folders {
            let name = URL(fileURLWithPath: folder).lastPathComponent
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                failures.append("The folder \(folder) is not there any more.")
                continue
            }
            do {
                let report = try await CrewDigestWriter.run(claudePath: claudePath, arguments: Self.arguments(agent: job.agent),
                                                            prompt: job.task, directory: URL(fileURLWithPath: folder),
                                                            timeout: timeout)
                reports.append(folders.count > 1 ? "## \(name)\n\n\(report.trimmingCharacters(in: .whitespacesAndNewlines))" : report)
            } catch {
                failures.append(folders.count > 1 ? "\(name): \(error.localizedDescription)" : error.localizedDescription)
            }
        }
        let findings = before.map { earlier in max(0, (ledgerCount(job.agent) ?? earlier) - earlier) }
        let report = reports.joined(separator: "\n\n")
        guard failures.isEmpty else {
            return Outcome(state: .failed, findings: reports.isEmpty ? nil : findings, note: failures.joined(separator: " "), report: report)
        }
        return Outcome(state: .done, findings: findings, report: report)
    }

    /// How many findings are in the member's ledger; nil when the member keeps none.
    private func ledgerCount(_ agent: String) -> Int? {
        let charter = homeDirectory.appendingPathComponent(".claude/agents/\(agent).md")
        guard let text = try? String(contentsOf: charter, encoding: .utf8), text.contains(CrewFindings.fileName) else { return nil }
        let ledger = homeDirectory.appendingPathComponent(".claude/agent-memory/\(agent)/\(CrewFindings.fileName)")
        return (try? String(contentsOf: ledger, encoding: .utf8)).map { CrewFindings.parse($0).count } ?? 0
    }
}
