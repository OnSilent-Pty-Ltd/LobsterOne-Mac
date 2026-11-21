import AppKit
import SwiftUI

/// The popover's Team page: the crew, one row each, with whatever needs attention marked on the
/// person it concerns. Reads only what `TeamMonitor` has; nothing on this page is uploaded.
struct TeamView: View {
    @ObservedObject var monitor: TeamMonitor
    /// The crew's calendar, for the short list of what is coming up. Nil where there is none to show.
    let calendar: CrewCalendarMonitor?
    /// The week's tokens across everything, for the crew's share. Nil when unknown.
    let weekTokens: Int?
    let now: Date
    let perform: (StatusBarController.PopoverAction) -> Void
    @State private var expandedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hPad: CGFloat = 16
    private static let aureliaID = CrewDigestWriter.agentName

    init(monitor: TeamMonitor, calendar: CrewCalendarMonitor? = nil, weekTokens: Int?, now: Date,
         perform: @escaping (StatusBarController.PopoverAction) -> Void, expandedID: String? = nil) {
        self.monitor = monitor
        self.calendar = calendar
        self.weekTokens = weekTokens
        self.now = now
        self.perform = perform
        self._expandedID = State(initialValue: expandedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = monitor.snapshot {
                if snapshot.members.isEmpty {
                    emptyCard
                } else {
                    header(snapshot)
                    crewCard(snapshot)
                    if let calendar {
                        ComingUpCard(calendar: calendar, members: snapshot.members) { perform(.crewCalendar) }
                            .padding(.horizontal, hPad)
                    }
                }
            } else {
                TeamLoadingCard(fraction: monitor.progress ?? 0)
                    .padding(.horizontal, hPad)
            }
        }
    }

    // MARK: - Header

    /// One line: what the crew cost this week.
    private func header(_ snapshot: TeamSnapshot) -> some View {
        let share = TeamFormat.share(snapshot.crewTokens, of: weekTokens)
        let tokens = "\(SevenDayBurn.formatTokens(snapshot.crewTokens)) tokens this week"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Your crew")
                .font(BrandFonts.sans(14, weight: .semibold))
            Spacer(minLength: 4)
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Refreshing")
            }
            Text(share.map { "\(tokens) · \(TeamFormat.percent($0))" } ?? tokens)
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, hPad + 2)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Crew

    /// Tall enough for a handful of rows and one open, shorter on small displays.
    private var listMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(520, max(240, screen - 380))
    }

    /// The members, then Aurelia, then a way to add someone. Whatever needs attention shows on the row it concerns.
    private func crewCard(_ snapshot: TeamSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(snapshot.members) { member in
                    TeamMemberRow(member: member, note: monitor.report.notes[member.name],
                                  attention: monitor.report.attention.first { $0.member == member.name },
                                  isWorking: monitor.working.contains(member.name), crewTokens: snapshot.crewTokens, now: now,
                                  isExpanded: expandedID == member.id,
                                  toggle: { toggle(member.id) },
                                  open: { perform(.openURL($0)) },
                                  seeChanges: { perform(.crewChanges(member.name)) },
                                  rule: { id, status in Task { await monitor.mark(status, finding: id, for: member.name) } },
                                  remove: member.persona == nil ? nil : { perform(.removeCrew(member.name)) })
                    divider
                }
                aureliaRow
                divider
                addRow
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: listMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, hPad)
    }

    private var divider: some View { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            expandedID = expandedID == id ? nil : id
        }
    }

    // MARK: - Aurelia

    /// The chief of staff, as one more row: her digest, and the decisions waiting in it.
    private var aureliaRow: some View {
        let isExpanded = expandedID == Self.aureliaID
        let decisions = monitor.digest?.openDecisions.count ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(Self.aureliaID) } label: {
                HStack(alignment: .center, spacing: 11) {
                    CrewFace(face: CrewDigestWriter.face, name: CrewDigestWriter.displayName)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(CrewDigestWriter.displayName)
                                .font(BrandFonts.sans(14, weight: .semibold))
                            if decisions > 0 {
                                TeamPill(text: decisions == 1 ? "1 decision" : "\(decisions) decisions", tone: .brand)
                            }
                        }
                        Text("Chief of staff")
                            .font(BrandFonts.sans(12))
                            .foregroundStyle(PopoverPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if monitor.isPreparingDigest {
                        ProgressView().controlSize(.small).accessibilityLabel("Preparing the digest")
                    } else {
                        Text(monitor.digest.map { "Digest \(TeamFormat.when($0.date, now: now))" } ?? "No digest yet")
                            .font(BrandFonts.sans(12))
                            .foregroundStyle(PopoverPalette.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the digest actions" : "Shows the digest actions")
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(monitor.isPreparingDigest
                         ? "Aurelia is reading the notebooks\u{2026}"
                         : "Once asked, she reads every charter, notebook and ledger and tells you what needs your eye.")
                        .font(BrandFonts.sans(13))
                        .fixedSize(horizontal: false, vertical: true)
                    if !monitor.isPreparingDigest {
                        HStack(spacing: 8) {
                            if monitor.digest != nil {
                                RowAction(title: "Read the digest", glyph: HorizonGlyphs.openExternal) { perform(.crewDigest) }
                            }
                            RowAction(title: monitor.digest == nil ? "Prepare a digest" : "Write a new one", glyph: HorizonGlyphs.refresh) {
                                Task { await monitor.prepareDigest() }
                            }
                        }
                    }
                    Text("Runs Claude Code once, on your plan.")
                        .font(BrandFonts.sans(11.5))
                        .foregroundStyle(PopoverPalette.tertiary)
                    if let problem = monitor.digestProblem {
                        Text(problem)
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.criticalText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .background(isExpanded ? PopoverPalette.cardHover : .clear)
    }

    // MARK: - Add

    private var addRow: some View {
        Button { perform(.hireCrew) } label: {
            HStack(spacing: 11) {
                Text("+")
                    .font(BrandFonts.sans(18, weight: .medium))
                    .foregroundStyle(PopoverPalette.secondary)
                    .frame(width: 36, height: 36)
                    .background(PopoverPalette.track, in: Circle())
                Text("Add to the crew")
                    .font(BrandFonts.sans(14, weight: .medium))
                    .foregroundStyle(PopoverPalette.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                // A handful of faces is an invitation; all fourteen would not fit the popover.
                ForEach(CrewRole.ready.prefix(5)) { role in
                    VStack(spacing: 4) {
                        CrewFace(face: role.face, name: role.name, size: 46)
                        Text(role.name)
                            .font(BrandFonts.sans(12, weight: .semibold))
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The town is looking for work")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text("Each keeps a charter and a notebook between sessions, so they remember what you decided last week. Start with one.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { perform(.hireCrew) } label: {
                Text("Meet the crew")
                    .font(BrandFonts.sans(13, weight: .semibold))
                    .foregroundStyle(PopoverPalette.onBrand)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(PopoverPalette.brand, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, hPad)
    }
}

/// What the crew is due to do next, and the way into the calendar.
struct ComingUpCard: View {
    @ObservedObject var calendar: CrewCalendarMonitor
    let members: [TeamMember]
    let open: () -> Void

    var body: some View {
        let entries = calendar.comingUp
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Coming up")
                        .font(BrandFonts.sans(12, weight: .semibold))
                        .foregroundStyle(PopoverPalette.secondary)
                    Spacer()
                    Text("Calendar")
                        .font(BrandFonts.sans(12.5, weight: .semibold))
                        .foregroundStyle(PopoverPalette.brandText)
                }
                if entries.isEmpty {
                    Text("Nothing planned. Give one of the crew a job for a set day and time.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(entries) { entry in row(entry) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the crew's calendar")
    }

    private func row(_ entry: CrewCalendar.Entry) -> some View {
        let person = CrewCalendar.person(entry.job.agent, members: members)
        return HStack(spacing: 10) {
            CrewFace(face: person.face, name: person.name, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.job.task)
                    .font(BrandFonts.sans(13, weight: .medium))
                    .lineLimit(1)
                Text("\(person.name) \u{00B7} \(Self.when(entry.due, now: calendar.today, calendar: calendar.calendar))")
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            Spacer(minLength: 0)
            if entry.status == .due {
                TeamPill(text: "Due", tone: .brand)
            } else if entry.status == .running {
                ProgressView().controlSize(.small).accessibilityLabel("Running")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "today, 17:30", "tomorrow, 09:00", "Mon 23 Nov, 09:00".
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = CrewJob.clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "today, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow, \(time)"
        }
        return "\(CrewJob.format(date, "EEE d MMM", calendar)), \(time)"
    }
}

/// A small label on a crew row saying what needs attention there.
struct TeamPill: View {
    enum Tone { case brand, warning, critical }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(BrandFonts.sans(11.5, weight: .semibold))
            .foregroundStyle(tone == .critical ? PopoverPalette.criticalText : tone == .warning ? PopoverPalette.warningText : PopoverPalette.brandText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(tone == .critical ? PopoverPalette.criticalBackground : tone == .warning ? PopoverPalette.warningBackground : PopoverPalette.blush,
                        in: Capsule())
    }
}

/// Shown while the first read is under way. It walks a week of transcripts and can take several
/// seconds, so it says how far it has got; before the first report it shows a spinner.
struct TeamLoadingCard: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Reading this week's runs\u{2026}")
                    .font(BrandFonts.sans(13.5))
                    .foregroundStyle(PopoverPalette.secondary)
                Spacer(minLength: 4)
                if fraction > 0 {
                    Text(TeamFormat.percent(fraction))
                        .font(BrandFonts.sans(12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PopoverPalette.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                }
            }
            ShareBar(fraction: fraction, height: 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading this week's runs")
        .accessibilityValue(TeamFormat.percent(fraction))
    }
}

/// A plain share-of-a-whole bar; a sliver still shows as a full round end.
struct ShareBar: View {
    let fraction: Double
    var height: CGFloat = 8
    var fill: Color = PopoverPalette.brand

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverPalette.track)
                Capsule().fill(fill).frame(width: clamped > 0 ? max(height, geo.size.width * clamped) : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One crew member: this week's cost against the rest of the crew, and on click the details.
struct TeamMemberRow: View {
    let member: TeamMember
    /// What the keeper knows: growth, and whether anything changed since the person last looked.
    var note: CrewNote?
    /// The most serious thing about this member that needs the person's eye, if anything does.
    var attention: CrewAttention?
    /// True while one of the member's runs is being written to.
    var isWorking = false
    let crewTokens: Int
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void
    let open: (URL) -> Void
    var seeChanges: () -> Void = {}
    /// Keeps or dismisses one of the member's open findings.
    var rule: (String, CrewFinding.Status) -> Void = { _, _ in }
    /// Open findings shown before the rest fold into a count.
    private static let findingsShown = 3
    /// Set for members the app hired; nil for agents the person wrote themselves.
    var remove: (() -> Void)?
    @State private var hovering = false
    @State private var confirmingRemoval = false

    private var title: String { member.displayName }
    private var share: Double { crewTokens > 0 ? Double(member.usage.tokens) / Double(crewTokens) : 0 }
    /// Green for a day after a run.
    private var recentlyActive: Bool {
        isWorking || (member.usage.lastRun.map { now.timeIntervalSince($0) < 24 * 3600 } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(isExpanded ? "Hides details" : "Shows details")
            if isExpanded {
                details.transition(.opacity)
            }
        }
        .background(hovering || isExpanded ? PopoverPalette.cardHover : .clear)
        .onHover { hovering = $0 }
    }

    private var activity: String {
        if isWorking { return "Working now" }
        guard member.usage.runs > 0, let last = member.usage.lastRun else { return "No runs this week" }
        return "\(TeamFormat.runs(member.usage.runs)) · \(TeamFormat.when(last, now: now))"
    }

    private var accessibilitySummary: String {
        member.usage.runs > 0
            ? "\(title), \(SevenDayBurn.formatTokens(member.usage.tokens)) tokens, \(activity)"
            : "\(title), no runs this week"
    }

    /// The few words that go beside the member's name.
    private var pill: (text: String, tone: TeamPill.Tone)? {
        guard let attention else { return nil }
        switch attention.kind {
        case .guardMissing: return ("Guard gone", .critical)
        case .charterEdited: return ("Charter edited", .brand)
        case .findings: return (attention.count == 1 ? "1 finding" : "\(attention.count) findings", .brand)
        case .notebookFull: return ("Notebook full", .warning)
        case .decisions: return nil
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .center, spacing: 11) {
            CrewFace(face: member.persona?.face, name: title)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(recentlyActive ? PopoverPalette.dotActive : PopoverPalette.dotOff)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(hovering || isExpanded ? PopoverPalette.cardHover : PopoverPalette.card, lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(BrandFonts.sans(14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    LineGlyph(data: HorizonGlyphs.chevronDown, size: 12, lineWidth: 2.2)
                        .foregroundStyle(PopoverPalette.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .opacity(hovering || isExpanded ? 1 : 0.5)
                    if let pill {
                        TeamPill(text: pill.text, tone: pill.tone)
                    } else if note?.hasUnseenChanges == true {
                        Circle().fill(PopoverPalette.brand).frame(width: 6, height: 6)
                            .help("Changed since you last looked")
                            .accessibilityLabel("Changed since you last looked")
                    }
                }
                if let role = member.persona?.title {
                    Text(role)
                        .font(BrandFonts.sans(12))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(member.usage.runs > 0 ? SevenDayBurn.formatTokens(member.usage.tokens) : "\u{2013}")
                    .font(BrandFonts.sans(15, weight: .semibold))
                Text(activity)
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: Details

    private struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var facts: [Fact] {
        var list: [Fact] = []
        if member.usage.runs > 0 {
            list.append(Fact(label: "Runs this week", value: "\(member.usage.runs)"))
            list.append(Fact(label: "Share of the crew", value: TeamFormat.percent(share)))
        }
        list.append(Fact(label: "Thinks with", value: TeamFormat.model(charter: member.model, lastRun: member.usage.lastModel)))
        if let project = member.usage.lastProject {
            list.append(Fact(label: "Last seen in", value: project))
        }
        if let changed = member.charterModified {
            list.append(Fact(label: "Charter", value: "Changed \(TeamFormat.when(changed, now: now))"))
        }
        list.append(Fact(label: "Notebook", value: notebookText))
        if let decided = note?.decidedFindings, decided.total > 0 {
            list.append(Fact(label: "Findings kept", value: "\(decided.kept) of \(decided.total)"))
        }
        return list
    }

    /// The charter's description; for a hired member, without the name it opens with and the
    /// "Use when asked for…" it closes with, which are there for Claude Code.
    private var summaryLine: String? {
        guard var text = member.description else { return nil }
        if let persona = member.persona {
            if text.hasPrefix("\(persona.name). ") { text = String(text.dropFirst(persona.name.count + 2)) }
            let tail = " Use when asked for \(persona.name)."
            if text.hasSuffix(tail) { text = String(text.dropLast(tail.count)) }
        }
        return text.isEmpty ? nil : text
    }

    private var notebookText: String {
        if let notebook = member.notebook {
            let lines = notebook.lines == 1 ? "1 line" : "\(notebook.lines) lines"
            if let growth = note?.notebookGrowth { return "\(lines) · \(TeamFormat.signed(growth)) this week" }
            return notebook.modified.map { "\(lines) · \(TeamFormat.when($0, now: now))" } ?? lines
        }
        switch member.memoryScope {
        case nil: return "Off"
        case "user": return "Empty"
        default: return "Kept per project"
        }
    }

    private static let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                                  GridItem(.flexible(), spacing: 12, alignment: .leading)]

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = summaryLine {
                Text(description)
                    .font(BrandFonts.sans(13))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let attention, attention.kind != .findings { issue(attention) }
            if let open = note?.openFindings, !open.isEmpty { findings(open) }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.label)
                            .font(BrandFonts.sans(11.5))
                            .foregroundStyle(PopoverPalette.secondary)
                        Text(fact.value)
                            .font(BrandFonts.sans(13.5, weight: .semibold))
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(TeamFormat.homePath(member.charterURL))
                .font(BrandFonts.mono(11.5))
                .foregroundStyle(PopoverPalette.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                RowAction(title: "Open charter", glyph: HorizonGlyphs.openExternal) { open(member.charterURL) }
                if let notebook = member.notebook {
                    RowAction(title: "Open notebook", glyph: HorizonGlyphs.openExternal) { open(notebook.url) }
                }
            }
            if note?.hasHistory == true {
                RowAction(title: "See what changed", glyph: HorizonGlyphs.refresh, action: seeChanges)
            }
            if let remove { removal(remove) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

extension TeamMemberRow {
    /// What is wrong, in a sentence, with the one thing to do about it.
    fileprivate func issue(_ item: CrewAttention) -> some View {
        let critical = item.kind == .guardMissing
        let warning = item.kind == .notebookFull
        let tint = critical ? PopoverPalette.criticalText : warning ? PopoverPalette.warningText : PopoverPalette.brandText
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.body)
                .font(BrandFonts.sans(12.5))
                .fixedSize(horizontal: false, vertical: true)
            if warning, let notebook = member.notebook {
                Button("Open the notebook") { open(notebook.url) }
                    .buttonStyle(.plain).font(BrandFonts.sans(12.5, weight: .semibold)).underline()
            } else if !warning {
                Button("See what changed") { seeChanges() }
                    .buttonStyle(.plain).font(BrandFonts.sans(12.5, weight: .semibold)).underline()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(critical ? PopoverPalette.criticalBackground : warning ? PopoverPalette.warningBackground : PopoverPalette.blush,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// The member's open findings, each waiting for a ruling. The ruling goes into the member's
    /// own ledger, so a dismissed finding is not raised again.
    fileprivate func findings(_ open: [CrewFinding]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(open.prefix(Self.findingsShown).enumerated()), id: \.element.id) { index, finding in
                if index > 0 { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.summary)
                        .font(BrandFonts.sans(13))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(finding.project) · \(finding.place)")
                        .font(BrandFonts.mono(11))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 14) {
                        Button("Keep") { rule(finding.id, .kept) }
                            .foregroundStyle(PopoverPalette.brandText)
                            .help("It was real. \(member.displayName) will say so if it comes back.")
                        Button("Dismiss") { rule(finding.id, .dismissed) }
                            .foregroundStyle(PopoverPalette.secondary)
                            .help("Not a problem. \(member.displayName) will not raise it again.")
                    }
                    .buttonStyle(.plain)
                    .font(BrandFonts.sans(12.5, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
            if open.count > Self.findingsShown {
                Rectangle().fill(PopoverPalette.divider).frame(height: 1)
                Text("\(open.count - Self.findingsShown) more in the ledger")
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 12))
    }

    /// "Let Bram go", then a second press to mean it. The notebook stays on disk either way.
    @ViewBuilder
    fileprivate func removal(_ remove: @escaping () -> Void) -> some View {
        if confirmingRemoval {
            HStack(spacing: 12) {
                Text("Let \(member.displayName) go? The notebook is kept.")
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Keep") { confirmingRemoval = false }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                Button("Let go") { remove() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(PopoverPalette.criticalText)
            }
            .font(BrandFonts.sans(12.5))
        } else {
            Button("Let \(member.displayName) go") { confirmingRemoval = true }
                .buttonStyle(.plain)
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(PopoverPalette.secondary)
        }
    }
}

// MARK: - Formatting

nonisolated enum TeamFormat {
    static func title(_ name: String) -> String { TeamScanner.title(name) }

    /// "+6" or, with a true minus sign, "−2".
    static func signed(_ value: Int) -> String { value < 0 ? "\u{2212}\(-value)" : "+\(value)" }

    static func runs(_ count: Int) -> String { count == 1 ? "1 run" : "\(count) runs" }

    /// Whole percent; a share too small to round up still reads as "<1%".
    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// The crew's share of the week, when the week's total is known and no smaller than the crew's.
    static func share(_ crew: Int, of week: Int?) -> Double? {
        guard let week, week > 0, crew <= week else { return nil }
        return Double(crew) / Double(week)
    }

    /// "just now", "12m ago", "3h ago", "yesterday", "Monday", then "12 Nov".
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) || seconds < 6 * 3600 { return "\(Int(seconds / 3600))h ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = days < 7 ? "EEEE" : "d MMM"
        return formatter.string(from: date)
    }

    /// The charter's model if it names one, else what the last run used.
    static func model(charter: String?, lastRun: String?) -> String {
        if let charter, charter != "inherit" { return modelName(charter) }
        if let lastRun { return modelName(lastRun) }
        return "The session's model"
    }

    /// "claude-opus-5-5" reads as "Opus 5.5"; an alias such as "opus" as "Opus".
    static func modelName(_ id: String) -> String {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    static func homePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
