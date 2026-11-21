import AppKit
import SwiftUI

/// The window for the crew's calendar, opened from the Agents page. Same size and look as the
/// hiring window.
@MainActor
final class CrewCalendarWindow {
    static let shared = CrewCalendarWindow()
    private var window: NSWindow?

    func show(calendar: CrewCalendarMonitor, team: TeamMonitor) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = CrewCalendarView(calendar: calendar, team: team, close: { [weak self] in self?.window?.close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Crew"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PopoverPalette.backgroundNS
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The crew's week, Monday first, with the picked job spelled out underneath; and the form for
/// adding or changing a job, in the same window at the same size.
struct CrewCalendarView: View {
    enum Mode: Equatable {
        case week
        /// Adding a job when `editing` is nil, else changing that one.
        case editor(editing: CrewJob?)
    }

    /// One time a job is due, as picked in the week. Kept apart from the entry so a job that is
    /// paused, and so drops out of the week ahead, can still be shown and resumed.
    struct Pick: Equatable {
        let job: UUID
        let due: Date
        var id: String { CrewRun.key(job: job, due: due) }
    }

    /// A run's report, for the sheet.
    struct Report: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let text: String
    }

    /// The form's fields, before they become a job.
    struct Draft {
        var agent: String?
        var task = ""
        var folders: [String] = []
        var repeats: CrewJob.Repeats = .weekdays
        /// Only the hour and minute count.
        var time: Date
        /// The day of a one-off job.
        var day: Date
        /// 1 is Monday, 7 is Sunday.
        var weekday: Int
        var dayOfMonth: Int
        /// False: the job starts by itself when its time comes.
        var asksFirst = false

        init(job: CrewJob?, agent: String?, now: Date, calendar: Calendar) {
            asksFirst = job?.asksFirst == true
            let today = calendar.startOfDay(for: now)
            let start = job?.first ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today) ?? today
            self.agent = job?.agent ?? agent
            task = job?.task ?? ""
            folders = job?.folders ?? []
            repeats = job?.repeats ?? .weekdays
            time = start
            day = job == nil ? today : calendar.startOfDay(for: start)
            weekday = (calendar.component(.weekday, from: start) + 5) % 7 + 1
            dayOfMonth = calendar.component(.day, from: start)
        }

        var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The first time the job is due at or after `now`. Daily and weekday jobs start today
        /// even when the time has passed, so today counts. A monthly job waits for a month that
        /// has its day, so a job for the 31st is not quietly moved to the 30th for good.
        func first(now: Date, calendar: Calendar) -> Date {
            let clock = calendar.dateComponents([.hour, .minute], from: time)
            func at(_ day: Date) -> Date {
                calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day) ?? day
            }
            let today = calendar.startOfDay(for: now)
            switch repeats {
            case .once: return at(calendar.startOfDay(for: day))
            case .daily, .weekdays:
                // A time already gone today starts tomorrow, so saving a job never sets off a reminder at once.
                if at(today) >= now { return at(today) }
                return at(calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            case .weekly, .monthly:
                for offset in 0..<400 {
                    guard let candidate = calendar.date(byAdding: .day, value: offset, to: today) else { break }
                    let moment = at(candidate)
                    guard moment >= now else { continue }
                    let fits = repeats == .weekly
                        ? calendar.component(.weekday, from: candidate) == weekday % 7 + 1
                        : calendar.component(.day, from: candidate) == dayOfMonth
                    if fits { return moment }
                }
                return at(today)
            }
        }

        /// Whether two drafts describe the same times, so an edit to the words alone keeps the
        /// job's start and its past on the calendar.
        func sameWhen(as other: Draft, calendar: Calendar) -> Bool {
            let mine = calendar.dateComponents([.hour, .minute], from: time)
            let theirs = calendar.dateComponents([.hour, .minute], from: other.time)
            guard repeats == other.repeats, mine.hour == theirs.hour, mine.minute == theirs.minute else { return false }
            switch repeats {
            case .once: return calendar.isDate(day, inSameDayAs: other.day)
            case .weekly: return weekday == other.weekday
            case .monthly: return dayOfMonth == other.dayOfMonth
            case .daily, .weekdays: return true
            }
        }
    }

    @ObservedObject var monitor: CrewCalendarMonitor
    @ObservedObject var team: TeamMonitor
    let close: () -> Void
    @State private var mode: Mode = .week
    /// Any day in the week on show.
    @State private var shown: Date
    @State private var pick: Pick?
    @State private var report: Report?
    @State private var draft: Draft
    /// The fields as they were when editing began.
    @State private var baseline: Draft?
    @State private var confirmingDelete = false

    init(calendar: CrewCalendarMonitor, team: TeamMonitor, mode: Mode = .week, close: @escaping () -> Void) {
        self.monitor = calendar
        self.team = team
        self.close = close
        let now = calendar.today
        _shown = State(initialValue: now)
        _mode = State(initialValue: mode)
        var editing: CrewJob?
        if case .editor(let job) = mode { editing = job }
        _draft = State(initialValue: Draft(job: editing, agent: nil, now: now, calendar: calendar.calendar))
        // Open on what is waiting today, else on today's first job.
        let today = calendar.week(containing: now).first { calendar.calendar.isDate($0.date, inSameDayAs: now) }?.entries ?? []
        let start = today.first { $0.status == .due } ?? today.first
        _pick = State(initialValue: start.map { Pick(job: $0.job.id, due: $0.due) })
    }

    private var cal: Calendar { monitor.calendar }
    private var members: [TeamMember] { team.snapshot?.members ?? [] }

    private func person(_ agent: String) -> (name: String, face: String?) {
        CrewCalendar.person(agent, members: members)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch mode {
                case .week: week
                case .editor(let editing): editor(editing)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: HireView.size.width, height: HireView.size.height)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
        .sheet(item: $report) { CrewReportSheet(report: $0) }
        .alert("Delete this job?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteEditing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(draft.agent.map { person($0).name } ?? "They") will no longer be asked to do it, and its past runs leave the calendar.")
        }
    }

    // MARK: - Pieces

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BrandFonts.sans(20, weight: .bold))
                .tracking(-0.03 * 20)
            Text(sub)
                .font(BrandFonts.sans(13))
                .foregroundStyle(PopoverPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(BrandFonts.sans(11.5, weight: .semibold))
            .foregroundStyle(PopoverPalette.secondary)
    }

    /// A task on one line, for headlines.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Week

    private var week: some View {
        let days = monitor.week(containing: shown)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 16) {
                heading("Calendar", range(days))
                Spacer(minLength: 0)
                weekControls
            }
            HStack(alignment: .top, spacing: 6) {
                ForEach(days) { dayColumn($0) }
            }
            .frame(maxHeight: .infinity)
            detail(selectedEntry(in: days))
        }
    }

    /// "16 to 22 November", or "30 November to 6 December" across two months.
    private func range(_ days: [CrewCalendar.Day]) -> String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        let sameMonth = cal.isDate(first, equalTo: last, toGranularity: .month)
        return "\(CrewJob.format(first, sameMonth ? "d" : "d MMMM", cal)) to \(CrewJob.format(last, "d MMMM", cal))"
    }

    private var weekControls: some View {
        HStack(spacing: 6) {
            navButton(turn: 90, label: "Previous week") { move(by: -7) }
            Button { shown = monitor.today } label: {
                Text("This week")
                    .font(BrandFonts.sans(12.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(PopoverPalette.card, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            navButton(turn: -90, label: "Next week") { move(by: 7) }
            let nobody = members.isEmpty
            Button { startEditing(nil) } label: {
                HStack(spacing: 5) {
                    LineGlyph(data: HorizonGlyphs.plus, size: 13, lineWidth: 2.4)
                    Text("New job")
                }
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(PopoverPalette.onBrand)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(PopoverPalette.brand, in: Capsule())
                .contentShape(Capsule())
                .opacity(nobody ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(nobody)
            .accessibilityLabel("New job")
            .accessibilityHint(nobody ? "Hire someone for the crew first." : "")
            .padding(.leading, 4)
            // A disabled button shows no tooltip of its own, so the hint sits on what holds it.
            .contentShape(Rectangle())
            .help(nobody ? "Hire someone for the crew first." : "Add a job for one of your crew.")
        }
    }

    private func navButton(turn: Double, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LineGlyph(data: HorizonGlyphs.chevronDown, size: 15, lineWidth: 2)
                .rotationEffect(.degrees(turn))
                .frame(width: 28, height: 28)
                .background(PopoverPalette.card, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func move(by days: Int) {
        shown = cal.date(byAdding: .day, value: days, to: shown) ?? shown
    }

    private func dayColumn(_ day: CrewCalendar.Day) -> some View {
        let isToday = cal.isDate(day.date, inSameDayAs: monitor.today)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(CrewJob.format(day.date, "EEE", cal))
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.secondary)
                Spacer(minLength: 0)
                Text(CrewJob.format(day.date, "d", cal))
                    .font(BrandFonts.sans(15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? PopoverPalette.brandText : PopoverPalette.text)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CrewJob.format(day.date, "EEEE d MMMM", cal) + (isToday ? ", today" : ""))
            .accessibilityAddTraits(.isHeader)
            if day.entries.isEmpty {
                Text("Nothing")
                    .font(BrandFonts.sans(11.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .opacity(0.7)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(day.entries) { entryCard($0) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? PopoverPalette.blush : PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func entryCard(_ entry: CrewCalendar.Entry) -> some View {
        let who = person(entry.job.agent)
        let selected = pick?.id == entry.id
        let missed = entry.status == .missed
        return Button {
            pick = Pick(job: entry.job.id, due: entry.due)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    CrewFace(face: who.face, name: who.name, size: 22)
                        .opacity(missed ? 0.5 : 1)
                    Text(CrewJob.clock(entry.due, calendar: cal))
                        .font(BrandFonts.mono(11))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                Text(Self.oneLine(entry.job.task))
                    .font(BrandFonts.sans(12, weight: missed ? .medium : .semibold))
                    .foregroundStyle(missed ? PopoverPalette.secondary : PopoverPalette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine(entry.status)
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(missed ? Color.clear : PopoverPalette.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(PopoverPalette.brand, lineWidth: 1.5)
                } else if missed {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(PopoverPalette.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(who.name), \(Self.oneLine(entry.job.task)), \(CrewJob.format(entry.due, "EEEE d MMMM", cal)) at \(CrewJob.clock(entry.due, calendar: cal)), \(Self.spoken(entry.status))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func statusLine(_ status: CrewCalendar.Status) -> some View {
        switch status {
        case .upcoming:
            EmptyView()
        case .due:
            Text("Due")
                .font(BrandFonts.sans(11, weight: .semibold))
                .foregroundStyle(PopoverPalette.brandText)
        case .running:
            Text("Running\u{2026}")
                .font(BrandFonts.sans(11))
                .foregroundStyle(PopoverPalette.secondary)
        case .done(let findings):
            HStack(spacing: 4) {
                LineGlyph(data: HorizonGlyphs.check, size: 10, lineWidth: 2.6)
                    .foregroundStyle(PopoverPalette.successText)
                Text(Self.findings(findings))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            .font(BrandFonts.sans(11))
        case .failed:
            Text("Did not finish")
                .font(BrandFonts.sans(11))
                .foregroundStyle(PopoverPalette.criticalText)
        case .missed:
            Text("Not run")
                .font(BrandFonts.sans(11))
                .foregroundStyle(PopoverPalette.secondary)
        }
    }

    private static func findings(_ count: Int?) -> String {
        guard let count else { return "Done" }
        switch count {
        case 0: return "Nothing found"
        case 1: return "1 finding"
        default: return "\(count) findings"
        }
    }

    private static func spoken(_ status: CrewCalendar.Status) -> String {
        switch status {
        case .upcoming: "coming up"
        case .due: "due"
        case .running: "running"
        case .done(let count): findings(count).lowercased()
        case .failed: "did not finish"
        case .missed: "not run"
        }
    }

    /// The picked time in the week on show. A paused job keeps its place here although the
    /// week no longer lists its days ahead, so it can be resumed from where it was paused.
    private func selectedEntry(in days: [CrewCalendar.Day]) -> CrewCalendar.Entry? {
        guard let pick else { return nil }
        if let entry = days.lazy.flatMap(\.entries).first(where: { $0.id == pick.id }) { return entry }
        guard let job = monitor.job(pick.job), job.paused,
              days.contains(where: { cal.isDate($0.date, inSameDayAs: pick.due) }) else { return nil }
        return CrewCalendar.Entry(job: job, due: pick.due, status: .upcoming)
    }

    // MARK: - Detail

    private static let detailHeight: CGFloat = 164

    @ViewBuilder
    private func detail(_ entry: CrewCalendar.Entry?) -> some View {
        if let entry {
            let job = entry.job
            let who = person(job.agent)
            let running = entry.status == .running
            let canRun = !running && (cal.isDate(entry.due, inSameDayAs: monitor.today) || entry.status == .missed)
            let text: String? = switch entry.status {
            case .done, .failed: monitor.report(for: entry)
            default: nil
            }
            HStack(alignment: .top, spacing: 14) {
                CrewFace(face: who.face, name: who.name, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(who.name): \(Self.oneLine(job.task))")
                        .font(BrandFonts.sans(16, weight: .bold))
                        .tracking(-0.02 * 16)
                        .lineLimit(1)
                    Text([job.schedule(calendar: cal), job.places,
                          job.startsItself ? nil : "Asks you first", job.paused ? "Paused" : nil]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.task)
                        .font(BrandFonts.mono(11.5))
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 9))
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                    Text(monitor.recent(job))
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(1)
                    if case .failed(let reason) = entry.status {
                        Text(reason)
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.criticalText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    CalendarButtons.primary(running ? "Running\u{2026}" : "Run now", small: true, enabled: canRun) {
                        Task { await monitor.run(job, due: entry.due) }
                    }
                    if let text {
                        CalendarButtons.secondary("See report", small: true) {
                            report = Report(id: entry.id, title: "\(who.name)\u{2019}s report",
                                            subtitle: "\(CrewJob.format(entry.due, "EEEE d MMMM", cal)), \(CrewJob.clock(entry.due, calendar: cal)) \u{00B7} \(Self.folderName(job.folder))",
                                            text: text)
                        }
                    }
                    CalendarButtons.secondary("Edit", small: true) { startEditing(monitor.job(job.id) ?? job) }
                    CalendarButtons.secondary(job.paused ? "Resume" : "Pause", small: true) {
                        monitor.setPaused(!job.paused, job: job.id)
                    }
                }
                .frame(width: 104)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: Self.detailHeight, maxHeight: Self.detailHeight, alignment: .topLeading)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 16))
        } else {
            Text(monitor.file.jobs.isEmpty ? "Nothing on the calendar yet. Add a job for one of your crew." : "Pick a job to see it.")
                .font(BrandFonts.sans(13))
                .foregroundStyle(PopoverPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.detailHeight, maxHeight: Self.detailHeight)
                .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Editor

    private func startEditing(_ job: CrewJob?) {
        let fresh = Draft(job: job, agent: members.first?.name, now: monitor.today, calendar: cal)
        draft = fresh
        baseline = job == nil ? nil : fresh
        mode = .editor(editing: job)
    }

    /// The job as the form describes it. An edit that leaves the times alone keeps the job's
    /// start, so its past stays on the calendar.
    private func plannedJob(_ editing: CrewJob?) -> CrewJob {
        let first: Date
        if let editing, let baseline, draft.sameWhen(as: baseline, calendar: cal) {
            first = editing.first
        } else {
            first = draft.first(now: monitor.today, calendar: cal)
        }
        var job = editing ?? CrewJob(agent: "", task: "", folder: "", repeats: draft.repeats, first: first)
        job.agent = draft.agent ?? ""
        job.task = draft.trimmedTask
        job.folders = draft.folders
        job.repeats = draft.repeats
        job.first = first
        job.asksFirst = draft.asksFirst ? true : nil
        return job
    }

    private var canSave: Bool {
        draft.agent != nil && !draft.trimmedTask.isEmpty && !draft.folders.isEmpty
    }

    private func editor(_ editing: CrewJob?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(editing == nil ? "New job" : "Edit job", "Something one of your crew does on a set day and time.")
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    form(editing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                plainWords(plannedJob(editing))
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func form(_ editing: CrewJob?) -> some View {
        // Someone who has left the crew still shows on their own job, so the form says whose it is.
        var who = members.map(\.name)
        if let agent = editing?.agent, !who.contains(agent) { who.append(agent) }
        return VStack(alignment: .leading, spacing: 7) {
            label("Who")
            ChipFlow(spacing: 6) {
                ForEach(who, id: \.self) { chip($0) }
            }
            if let agent = draft.agent { goodAt(agent) }
            label("What").padding(.top, 9)
            TextField(taskPrompt, text: $draft.task, axis: .vertical)
                .lineLimit(3...3)
                .textFieldStyle(.plain)
                .font(BrandFonts.sans(13.5))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PopoverPalette.lineStrong, lineWidth: 1))
                .accessibilityLabel("What")
            label("Where").padding(.top, 9)
            // One line per folder; the job is done in each, one after another.
            VStack(spacing: 0) {
                ForEach(draft.folders, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Text(TeamFormat.homePath(URL(fileURLWithPath: folder)))
                            .font(BrandFonts.mono(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { draft.folders.removeAll { $0 == folder } } label: {
                            Text("Remove")
                                .font(BrandFonts.sans(12, weight: .medium))
                                .foregroundStyle(PopoverPalette.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(Self.folderName(folder))")
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    Rectangle().fill(PopoverPalette.lineStrong).frame(height: 1)
                }
                Button(action: chooseFolder) {
                    HStack(spacing: 10) {
                        Text(draft.folders.isEmpty ? "No folder yet" : draft.folders.count == 1 ? "Add another, to do the same job there too" : "Add another")
                            .font(BrandFonts.sans(13))
                            .foregroundStyle(PopoverPalette.secondary)
                        Spacer(minLength: 0)
                        Text(draft.folders.isEmpty ? "Choose\u{2026}" : "Add\u{2026}")
                            .font(BrandFonts.sans(12.5, weight: .semibold))
                            .foregroundStyle(PopoverPalette.brandText)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draft.folders.isEmpty ? "Choose a folder" : "Add another folder")
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PopoverPalette.lineStrong, lineWidth: 1))
            label("When").padding(.top, 9)
            repeatsChoice
            whenControls
            label("When it\u{2019}s due").padding(.top, 9)
            dueChoice
            Text(draft.asksFirst
                 ? "You get a notification with a Run button. Nothing starts until you click."
                 : "Starts at the set time, as long as your Mac is awake and LobsterOne is running. You get a notification when it is done.")
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A reminder of what the chosen member is for, so the job asked of them fits.
    private func goodAt(_ agent: String) -> some View {
        let strengths = CrewCalendar.strengths(agent, members: members)
        let title = strengths.title.map { Text("\($0). ").fontWeight(.semibold) } ?? Text("")
        let does = Text(strengths.does ?? "No description in this charter.").foregroundColor(PopoverPalette.secondary)
        return (title + does)
            .font(BrandFonts.sans(12.5))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
    }

    /// The prompt in the empty What field, with an example that suits the chosen member.
    private var taskPrompt: String {
        guard let agent = draft.agent else { return "What should they do?" }
        let name = person(agent).name
        guard let example = CrewCalendar.strengths(agent, members: members).example else { return "What should \(name) do?" }
        return "What should \(name) do? For example: \(example)"
    }

    /// Whether the job starts by itself or waits for a click.
    private var dueChoice: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { asks in
                let on = draft.asksFirst == asks
                Button { draft.asksFirst = asks } label: {
                    Text(asks ? "Ask me first" : "Run on its own")
                        .font(BrandFonts.sans(12.5, weight: .semibold))
                        .foregroundStyle(on ? PopoverPalette.text : PopoverPalette.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(on ? PopoverPalette.background : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("When it\u{2019}s due")
    }

    private func chip(_ agent: String) -> some View {
        let who = person(agent)
        let on = draft.agent == agent
        return Button { draft.agent = agent } label: {
            HStack(spacing: 7) {
                CrewFace(face: who.face, name: who.name, size: 30)
                Text(who.name)
                    .font(BrandFonts.sans(13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? PopoverPalette.brandText : PopoverPalette.text)
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(on ? PopoverPalette.blush : PopoverPalette.card, in: Capsule())
            .overlay(Capsule(style: .circular).inset(by: 0.75).stroke(on ? PopoverPalette.brand : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(who.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var repeatsChoice: some View {
        HStack(spacing: 2) {
            ForEach(CrewJob.Repeats.allCases, id: \.self) { option in
                let on = draft.repeats == option
                Button { draft.repeats = option } label: {
                    Text(option.label)
                        .font(BrandFonts.sans(12.5, weight: .semibold))
                        .foregroundStyle(on ? PopoverPalette.text : PopoverPalette.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(on ? PopoverPalette.background : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repeats")
    }

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private var whenControls: some View {
        HStack(spacing: 8) {
            switch draft.repeats {
            case .once:
                Text("on").foregroundStyle(PopoverPalette.secondary)
                DatePicker("Day", selection: $draft.day, in: cal.startOfDay(for: monitor.today)..., displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
            case .weekly:
                Text("on").foregroundStyle(PopoverPalette.secondary)
                Picker("Weekday", selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case .monthly:
                Text("on day").foregroundStyle(PopoverPalette.secondary)
                Stepper(value: $draft.dayOfMonth, in: 1...31) {
                    Text("\(draft.dayOfMonth)")
                        .monospacedDigit()
                        .frame(minWidth: 20, alignment: .trailing)
                }
                .accessibilityLabel("Day of the month")
                .accessibilityValue("\(draft.dayOfMonth)")
            case .daily, .weekdays:
                EmptyView()
            }
            Text("at").foregroundStyle(PopoverPalette.secondary)
            DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
        }
        .font(BrandFonts.sans(13.5))
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.calendar, cal)
        .environment(\.timeZone, cal.timeZone)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Pick the folders the job is done in. Hold Command to pick several."
        if let last = draft.folders.last { panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent() }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.folders.contains(url.path) { draft.folders.append(url.path) }
    }

    /// The job read back as a sentence, with its next three times, so a wrong time is caught
    /// before it is saved.
    private func plainWords(_ job: CrewJob) -> some View {
        let who = draft.agent.map(person)
        let task = draft.trimmedTask
        let short = task.count > 90 ? String(task.prefix(90)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : task
        let next = job.occurrences(from: cal.startOfDay(for: monitor.today),
                                   to: cal.date(byAdding: .day, value: 400, to: monitor.today) ?? monitor.today,
                                   calendar: cal).prefix(3)
        let missing = { (text: String) in Text(text).foregroundStyle(PopoverPalette.secondary) }
        let name = who.map { Text($0.name) } ?? missing("someone")
        let what = task.isEmpty ? missing("what you ask") : Text("\u{201C}\(Self.oneLine(short))\u{201D}")
        let place = draft.folders.isEmpty ? missing("a folder") : Text(CrewJob.places(draft.folders))
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if let who {
                    CrewFace(face: who.face, name: who.name, size: 92)
                } else {
                    LineGlyph(data: HorizonGlyphs.people, size: 34, lineWidth: 1.6)
                        .foregroundStyle(PopoverPalette.secondary)
                        .frame(width: 92, height: 92)
                        .background(PopoverPalette.card, in: Circle())
                }
            }
            .padding(5)
            .background(PopoverPalette.background, in: Circle())
            if let who, let agent = draft.agent {
                Text(who.name)
                    .font(BrandFonts.sans(22, weight: .bold))
                    .tracking(-0.03 * 22)
                    .padding(.top, 12)
                if let title = CrewCalendar.strengths(agent, members: members).title {
                    Text(title)
                        .font(BrandFonts.sans(13))
                        .foregroundStyle(PopoverPalette.secondary)
                }
            }
            Text("IN PLAIN WORDS")
                .font(BrandFonts.sans(11.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(PopoverPalette.brandText)
                .padding(.top, 18)
                .padding(.bottom, 4)
            (draft.asksFirst
             ? Text("\(job.schedule(calendar: cal)), you are reminded to send \(name) off on: \(what) in \(place).")
             : Text("\(job.schedule(calendar: cal)), \(name) gets to work on: \(what) in \(place)."))
                .font(BrandFonts.sans(17, weight: .semibold))
                .tracking(-0.01 * 17)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 3) {
                label("Next three").padding(.bottom, 3)
                if next.isEmpty {
                    Text("That time has passed.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                } else {
                    ForEach(Array(next), id: \.self) { date in
                        Text(nextLabel(date)).font(BrandFonts.mono(11.5))
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    /// "Today, 17:30", "Tomorrow, 09:00", "Mon 23 Nov, 17:30".
    private func nextLabel(_ date: Date) -> String {
        let time = CrewJob.clock(date, calendar: cal)
        if cal.isDate(date, inSameDayAs: monitor.today) { return "Today, \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: monitor.today), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow, \(time)"
        }
        return "\(CrewJob.format(date, "EEE d MMM", cal)), \(time)"
    }

    private func save(_ editing: CrewJob?) {
        guard canSave else { return }
        let job = plannedJob(editing)
        monitor.save(job)
        // Land on the job's next time, picked, so the person sees where it went.
        let start = cal.startOfDay(for: monitor.today)
        if let due = job.occurrences(from: start, to: cal.date(byAdding: .day, value: 400, to: start) ?? start, calendar: cal).first {
            shown = due
            pick = Pick(job: job.id, due: due)
        } else {
            pick = nil
        }
        mode = .week
    }

    private func deleteEditing() {
        guard case .editor(let editing?) = mode else { return }
        monitor.delete(editing.id)
        pick = nil
        mode = .week
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            switch mode {
            case .week:
                if let problem = monitor.problem {
                    Text(problem)
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.criticalText)
                        .lineLimit(2)
                } else {
                    Text("Jobs start when their time comes, if your Mac is awake and LobsterOne is running.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                Spacer()
                CalendarButtons.secondary("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            case .editor(let editing):
                CalendarButtons.secondary("Cancel") { mode = .week }
                    .keyboardShortcut(.cancelAction)
                if editing != nil {
                    CalendarButtons.quiet("Delete") { confirmingDelete = true }
                }
                Spacer()
                CalendarButtons.primary(editing == nil ? "Add to the calendar" : "Save", enabled: canSave) { save(editing) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The capsule buttons from the hiring window, with a smaller size for the week's controls and
/// a dimmed look when they cannot be used.
@MainActor
private enum CalendarButtons {
    static func primary(_ title: String, small: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(small ? 12.5 : 13, weight: .semibold))
                .foregroundStyle(PopoverPalette.onBrand)
                .lineLimit(1)
                .padding(.horizontal, small ? 13 : 16)
                .frame(maxWidth: small ? .infinity : nil)
                .frame(height: small ? 28 : 32)
                .background(PopoverPalette.brand, in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    static func secondary(_ title: String, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(small ? 12.5 : 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, small ? 13 : 16)
                .frame(maxWidth: small ? .infinity : nil)
                .frame(height: small ? 28 : 32)
                .background(PopoverPalette.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    static func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .medium))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.horizontal, 6)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One run's report, as the member wrote it.
private struct CrewReportSheet: View {
    let report: CrewCalendarView.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title)
                        .font(BrandFonts.sans(20, weight: .bold))
                        .tracking(-0.03 * 20)
                    Text(report.subtitle)
                        .font(BrandFonts.sans(13))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ScrollView {
                    Text(report.text)
                        .font(BrandFonts.mono(11.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)
            Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            HStack {
                Spacer()
                CalendarButtons.primary("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 520)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
    }
}

/// Left-to-right wrapping layout for the crew chips in the form.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [i], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(i)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
