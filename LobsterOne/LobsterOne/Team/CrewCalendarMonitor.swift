import Combine
import Foundation

/// Holds the calendar for the windows and the Agents page and notices when a job comes due.
/// A job set to start by itself is run then; one set to ask first waits for the person.
@MainActor
final class CrewCalendarMonitor: ObservableObject {
    @Published private(set) var file = CrewCalendarFile()
    /// Why the last save or run could not be recorded, in a sentence.
    @Published private(set) var problem: String?

    /// Called once for each ask-first job as its time comes, so the person can be told.
    var onDue: (([(job: CrewJob, due: Date)]) -> Void)?
    /// Called when a job that started by itself has finished, with what came of it.
    var onFinished: ((CrewJob, CrewRun) -> Void)?
    /// The jobs that started by themselves and are still to finish, so the app can wait for them.
    private(set) var selfStarted: Task<Void, Never>?

    let calendar: Calendar
    private let store: CrewCalendarStore
    private let runJob: @Sendable (CrewJob) async -> CrewJobRunner.Outcome
    private let now: () -> Date
    private var timer: Timer?

    init(store: CrewCalendarStore = CrewCalendarStore(), calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (CrewJob) async -> CrewJobRunner.Outcome = { job in
             await CrewJobRunner().run(job, claudePath: ClaudeCredentialService.resolveClaudeBinary())
         }) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.runJob = run
    }

    /// Reads the calendar and starts looking at the clock twice a minute.
    func start() {
        file = store.load()
        // A run cut short by the app quitting would otherwise show as running for ever.
        for index in file.runs.indices where file.runs[index].state == .running {
            file.runs[index].state = .failed
            file.runs[index].note = "LobsterOne quit while it was running."
        }
        persist()
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Records each job whose time has come, once. Those that ask first are announced and wait;
    /// the rest are started, one after another so two jobs never draw on the plan at once.
    func tick() {
        let due = CrewCalendar.newlyDue(file, now: now(), calendar: calendar)
        guard !due.isEmpty else { return }
        file.runs.append(contentsOf: due.map { CrewRun(job: $0.job.id, due: $0.due, state: .waiting) })
        persist()
        let asking = due.filter { !$0.job.startsItself }
        if !asking.isEmpty { onDue?(asking) }
        let starting = due.filter { $0.job.startsItself }
        guard !starting.isEmpty else { return }
        let earlier = selfStarted
        selfStarted = Task { [weak self] in
            await earlier?.value
            for item in starting {
                guard let self else { return }
                await self.run(item.job, due: item.due)
                if let run = self.file.runs.first(where: { $0.id == CrewRun.key(job: item.job.id, due: item.due) }) {
                    self.onFinished?(item.job, run)
                }
            }
        }
    }

    // MARK: - Reading

    func week(containing date: Date) -> [CrewCalendar.Day] {
        CrewCalendar.week(file, containing: date, now: now(), calendar: calendar)
    }

    var comingUp: [CrewCalendar.Entry] {
        CrewCalendar.comingUp(file, now: now(), calendar: calendar)
    }

    var today: Date { now() }

    func job(_ id: UUID) -> CrewJob? { file.jobs.first { $0.id == id } }

    /// A sentence on how a job has done lately: "Last 7 days: 4 runs, 3 findings."
    func recent(_ job: CrewJob) -> String {
        let since = now().addingTimeInterval(-7 * 86_400)
        let runs = file.runs.filter { $0.job == job.id && $0.state == .done && $0.due >= since }
        guard !runs.isEmpty else { return "No runs in the last 7 days." }
        let count = "\(runs.count) \(runs.count == 1 ? "run" : "runs")"
        guard runs.contains(where: { $0.findings != nil }) else { return "Last 7 days: \(count)." }
        let findings = runs.compactMap(\.findings).reduce(0, +)
        return "Last 7 days: \(count), \(findings) \(findings == 1 ? "finding" : "findings")."
    }

    func report(for entry: CrewCalendar.Entry) -> String? {
        file.runs.first { $0.id == entry.id }.flatMap(store.report(for:))
    }

    // MARK: - Changing

    /// Adds a job, or replaces the one with the same id.
    func save(_ job: CrewJob) {
        if let index = file.jobs.firstIndex(where: { $0.id == job.id }) {
            file.jobs[index] = job
        } else {
            file.jobs.append(job)
        }
        persist()
        // A job set for a time already past today is due at once.
        tick()
    }

    func delete(_ id: UUID) {
        file.jobs.removeAll { $0.id == id }
        file.runs.removeAll { $0.job == id }
        persist()
    }

    func setPaused(_ paused: Bool, job id: UUID) {
        guard let index = file.jobs.firstIndex(where: { $0.id == id }) else { return }
        file.jobs[index].paused = paused
        persist()
    }

    /// Runs one occurrence of a job because the person asked, and records what came of it.
    func run(_ job: CrewJob, due: Date) async {
        let key = CrewRun.key(job: job.id, due: due)
        if let existing = file.runs.first(where: { $0.id == key }), existing.state == .running { return }
        record(CrewRun(job: job.id, due: due, state: .running, started: now()))
        let outcome = await runJob(job)
        let finished = CrewRun(job: job.id, due: due, state: outcome.state, started: file.runs.first { $0.id == key }?.started,
                               finished: now(), findings: outcome.findings, note: outcome.note)
        if !outcome.report.isEmpty { store.saveReport(outcome.report, for: finished) }
        record(finished)
    }

    /// The occurrence a notification named, if the job still exists.
    func run(key: String) async {
        guard let run = file.runs.first(where: { $0.id == key }), let job = job(run.job) else { return }
        await self.run(job, due: run.due)
    }

    private func record(_ run: CrewRun) {
        file.runs.removeAll { $0.id == run.id }
        file.runs.append(run)
        persist()
    }

    private func persist() {
        do {
            try store.save(file)
            problem = nil
        } catch {
            problem = "The calendar could not be saved: \(error.localizedDescription)"
        }
    }
}

extension CrewCalendar {
    /// Something worth putting on a calendar for each of the town's roles, shown as an example
    /// while the person writes their own.
    nonisolated static let examples: [String: String] = [
        "security-reviewer": "Review everything merged to main since your last review.",
        "release-reviewer": "Check the release branch against what was planned for this week.",
        "data-analyst": "Read this week's export and say what changed since last week.",
        "bug-catcher": "Trace the newest failure in the logs folder to its cause.",
        "linter": "Look over everything committed today for small slips.",
        "copy-editor": "Read the words added to the interface this week.",
        "design-reviewer": "Review the screens changed this week.",
        "fresh-eyes": "Read the README as a newcomer and say where you get lost.",
        "tooling-reviewer": "Look over the dev setup and say what has gone slow or fragile.",
        "pipeline-reviewer": "Review the CI and release workflows for anything slow, flaky or unsafe.",
        "upkeep-reviewer": "Walk the project and say what needs upkeep.",
        "cleanup-reviewer": "Find what can be removed from the Sources folder.",
        "growth-analyst": "Walk through the sign-up flow and say where people would drop out.",
        "experiment-designer": "Check this week's experiment results against the plan.",
        "cost-controller": "Go through the infrastructure and say what costs more than it should.",
        "seo-specialist": "Review the public pages changed this week for search.",
    ]

    /// What a member is good at, to help the person word a job: the job title, the sentence from
    /// the charter, and an example to ask.
    @MainActor
    static func strengths(_ agent: String, members: [TeamMember]) -> (title: String?, does: String?, example: String?) {
        if let role = CrewRole.ready.first(where: { $0.id == agent }) {
            return (role.title, role.does, examples[agent])
        }
        guard let member = members.first(where: { $0.name == agent }) else { return (nil, nil, nil) }
        // A charter's description reads "Name. What they do. Use when asked for Name."
        var does = member.description ?? ""
        if let name = member.persona?.name {
            if does.hasPrefix("\(name). ") { does.removeFirst(name.count + 2) }
            let ending = " Use when asked for \(name)."
            if does.hasSuffix(ending) { does.removeLast(ending.count) }
        }
        let title = member.persona?.title
        return (title == member.persona?.name ? nil : title, does.isEmpty ? nil : does, nil)
    }

    /// Who a job belongs to, for showing: the hired member's name and face, or the town's if the
    /// charter is not in the snapshot yet.
    @MainActor
    static func person(_ agent: String, members: [TeamMember]) -> (name: String, face: String?) {
        if let member = members.first(where: { $0.name == agent }), let persona = member.persona {
            return (persona.name, persona.face)
        }
        if let role = CrewRole.ready.first(where: { $0.id == agent }) { return (role.name, role.face) }
        return (TeamScanner.title(agent), nil)
    }
}
