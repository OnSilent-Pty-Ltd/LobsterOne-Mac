import AppKit
import SwiftUI

/// The small window for hiring a crew member, opened from the popover's Team page.
@MainActor
final class CrewWindow {
    static let shared = CrewWindow()
    private var window: NSWindow?

    func show(onChange: @escaping () -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = HireView(onChange: onChange, close: { [weak self] in self?.window?.close() })
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

/// Three steps: pick a person and meet them on one screen, read the charter, then a first job to try.
struct HireView: View {
    enum Step: Equatable { case pick, charter, done }

    /// Who is being hired: one of the ready roles, or someone new under a name you give.
    enum Choice: Equatable {
        case role(CrewRole)
        case someoneNew
    }

    let installer: CrewInstaller
    let onChange: () -> Void
    let close: () -> Void
    @State private var step: Step
    @State private var choice: Choice
    @State private var newName = ""
    @State private var newJob = ""
    @State private var model: CrewInstaller.Model = .opus
    @State private var failure: String?
    @State private var copied = false
    @State private var showsMore: Bool

    /// The app's one window size, for every step, so the window never jumps as you go through them.
    static var size: CGSize { AppWindow.fitted }

    init(installer: CrewInstaller = CrewInstaller(), step: Step = .pick, choice: Choice? = nil,
         onChange: @escaping () -> Void, close: @escaping () -> Void) {
        self.installer = installer
        self.onChange = onChange
        self.close = close
        self._step = State(initialValue: step)
        // Start on the first person not yet on the crew.
        let firstFree = (CrewRole.featured + CrewRole.more).first { !FileManager.default.fileExists(atPath: installer.charterURL(for: $0).path) }
        let start = choice ?? firstFree.map(Choice.role) ?? .someoneNew
        self._choice = State(initialValue: start)
        // Someone from behind "Show more" is only a sensible start if they can be seen.
        if case .role(let role) = start, CrewRole.more.contains(role) {
            self._showsMore = State(initialValue: true)
        } else {
            self._showsMore = State(initialValue: false)
        }
    }

    /// The role as it would be hired; nil while "someone new" has no name or job yet.
    private var role: CrewRole? {
        switch choice {
        case .role(let role): role
        case .someoneNew: CrewRole.custom(name: newName, job: newJob)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .pick: pick
                case .charter: charter
                case .done: done
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
        .frame(width: Self.size.width, height: Self.size.height)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
    }

    // MARK: - Pieces

    private func heading(_ number: Int?, _ title: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let number {
                Text("Step \(number) of 2")
                    .font(BrandFonts.sans(12, weight: .semibold))
                    .foregroundStyle(PopoverPalette.brandText)
            }
            Text(title)
                .font(BrandFonts.sans(20, weight: .bold))
                .tracking(-0.03 * 20)
            if let sub {
                Text(sub)
                    .font(BrandFonts.sans(13))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isHired(_ role: CrewRole) -> Bool {
        CrewInstaller.isOurs(installer.charterURL(for: role))
    }

    // MARK: - Step 1

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: 3)

    /// The roster on the left, the one you picked on the right.
    private var pick: some View {
        // Those already on the crew follow the ones you can pick, whichever group they came from.
        let hired = CrewRole.ready.filter(isHired)
        // The extra agents are added after the ones already showing, so nobody moves when they appear.
        let open = (CrewRole.featured + (showsMore ? CrewRole.more : [])).filter { !hired.contains($0) }
        let waiting = CrewRole.more.filter { !hired.contains($0) }.count
        return VStack(alignment: .leading, spacing: 16) {
            heading(1, hired.isEmpty ? "Who's first?" : "Who's next?",
                    hired.isEmpty ? "Pick one. You can hire the others later." : "Pick one.")
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                LazyVGrid(columns: Self.columns, spacing: 2) {
                                    ForEach(open) { role in
                                        person(face: role.face, name: role.name, job: role.title,
                                               selected: choice == .role(role), hired: false) {
                                            failure = nil
                                            choice = .role(role)
                                        }
                                        .id(role.id)
                                    }
                                    ForEach(hired) { role in
                                        person(face: role.face, name: role.name, job: "On the crew", selected: false, hired: true) {}
                                            .disabled(true)
                                    }
                                }
                                if waiting > 0 { moreButton(waiting).id(Self.moreButtonID) }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        // The full list is a little taller than its space; bring the new faces into view.
                        .onChange(of: showsMore) {
                            guard showsMore else { return }
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.moreButtonID, anchor: .bottom) }
                        }
                        .onAppear {
                            if showsMore, case .role(let role) = choice { proxy.scrollTo(role.id, anchor: .center) }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    createButton.padding(.top, 10)
                    // With the whole roster open the panel folds to a line, to leave the list its room.
                    teamPanel(compact: showsMore).padding(.top, 12)
                }
                .frame(width: 318)
                stage
            }
        }
    }

    private static let moreButtonID = "show-more"

    /// Reveals the agents not shown at first, in the same grid.
    private func moreButton(_ count: Int) -> some View {
        Button {
            // Folding the list away must not leave a hidden person picked.
            if showsMore, case .role(let role) = choice, CrewRole.more.contains(role) {
                choice = CrewRole.featured.first { !isHired($0) }.map(Choice.role) ?? .someoneNew
            }
            showsMore.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(showsMore ? "Show fewer" : "Show \(count) more")
                LineGlyph(data: HorizonGlyphs.chevronDown, size: 14, lineWidth: 2)
                    .rotationEffect(.degrees(showsMore ? 180 : 0))
            }
            .font(BrandFonts.sans(12.5, weight: .semibold))
            .foregroundStyle(PopoverPalette.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Writing your own agent is a button of its own, not a face in the roster.
    private var createButton: some View {
        let selected = choice == .someoneNew
        return Button {
            failure = nil
            choice = .someoneNew
        } label: {
            HStack(spacing: 6) {
                LineGlyph(data: HorizonGlyphs.plus, size: 14, lineWidth: 2.2)
                Text("Create your own")
            }
            .font(BrandFonts.sans(13, weight: .semibold))
            .foregroundStyle(selected ? PopoverPalette.brandText : PopoverPalette.text)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(selected ? PopoverPalette.blush : PopoverPalette.card, in: Capsule())
            .overlay(Capsule(style: .circular).inset(by: 0.75).stroke(selected ? PopoverPalette.brand : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Where agents shared across a team will appear, for those on LobsterOne for Teams.
    private func teamPanel(compact: Bool) -> some View {
        Button {
            if let url = URL(string: Constants.teamsURL) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: compact ? .center : .top, spacing: 11) {
                LineGlyph(data: HorizonGlyphs.people, size: compact ? 15 : 17, lineWidth: 1.8)
                    .foregroundStyle(PopoverPalette.brandText)
                    .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                    .background(PopoverPalette.blush, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents your team shares")
                        .font(BrandFonts.sans(13, weight: .semibold))
                    if !compact {
                        Text("With LobsterOne for Teams, agents your teammates share show up here, and you can share yours.")
                            .font(BrandFonts.sans(12))
                            .foregroundStyle(PopoverPalette.secondary)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("See LobsterOne for Teams \u{2192}")
                            .font(BrandFonts.sans(12.5, weight: .semibold))
                            .foregroundStyle(PopoverPalette.brandText)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if compact {
                    Text("For Teams \u{2192}")
                        .font(BrandFonts.sans(12.5, weight: .semibold))
                        .foregroundStyle(PopoverPalette.brandText)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 8 : 12)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PopoverPalette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agents your team shares. With LobsterOne for Teams, agents your teammates share show up here, and you can share yours.")
        .accessibilityHint("Opens the LobsterOne for Teams page in your browser")
    }

    private func person(face: String, name: String, job: String, selected: Bool, hired: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                CrewFace(face: face, name: name, size: 46)
                    .padding(4)
                    .overlay(Circle().stroke(selected ? PopoverPalette.brand : Color.clear, lineWidth: 2.5))
                    .overlay(alignment: .bottomTrailing) {
                        if hired {
                            LineGlyph(data: HorizonGlyphs.check, size: 10, lineWidth: 2.2)
                                .foregroundStyle(PopoverPalette.successText)
                                .frame(width: 18, height: 18)
                                .background(PopoverPalette.successBackground, in: Circle())
                                .overlay(Circle().stroke(PopoverPalette.background, lineWidth: 2))
                        }
                    }
                    .padding(.bottom, 2)
                Text(name)
                    .font(BrandFonts.sans(13, weight: .semibold))
                    .foregroundStyle(selected ? PopoverPalette.brandText : hired ? PopoverPalette.secondary : PopoverPalette.text)
                    .lineLimit(1)
                Text(job)
                    .font(BrandFonts.sans(11.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(job)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The person you picked, introduced: who they are in town, what they say, what they do.
    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch choice {
            case .role(let role):
                stageFace(role.face, name: role.name)
                Text(role.townJob.uppercased())
                    .font(BrandFonts.sans(11.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(PopoverPalette.brandText)
                    .padding(.top, 18)
                Text(role.name)
                    .font(BrandFonts.sans(34, weight: .bold))
                    .tracking(-0.04 * 34)
                Text("\u{201C}\(role.quote)\u{201D}")
                    .font(BrandFonts.sans(16, weight: .medium))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Text(role.does)
                    .font(BrandFonts.sans(13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                Text("\(role.works) \(role.touches)")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Spacer(minLength: 16)
                Text("Try first")
                    .font(BrandFonts.sans(11.5, weight: .semibold))
                    .foregroundStyle(PopoverPalette.secondary)
                Text(role.firstJob)
                    .font(BrandFonts.mono(11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 6)
            case .someoneNew:
                stageFace("newcomer", name: "Your own agent")
                Text("NEW IN TOWN")
                    .font(BrandFonts.sans(11.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(PopoverPalette.brandText)
                    .padding(.top, 18)
                field("Their name", text: $newName, size: 22, weight: .bold, lines: 1)
                    .accessibilityLabel("Name")
                    .padding(.top, 8)
                field("What should they do? For example: checks database migrations before they run.",
                      text: $newJob, size: 13.5, weight: .regular, lines: 3)
                    .accessibilityLabel("Job")
                    .padding(.top, 8)
                Text("Like the rest of the crew, they read your project and write only in their own notebook.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Spacer(minLength: 16)
            }
            if let failure { failureText(failure).padding(.top, 10) }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A complaint about the fields goes away as soon as they are being filled in.
        .onChange(of: newName) { failure = nil }
        .onChange(of: newJob) { failure = nil }
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func stageFace(_ face: String, name: String) -> some View {
        CrewFace(face: face, name: name, size: 116)
            .padding(5)
            .background(PopoverPalette.background, in: Circle())
    }

    private func field(_ prompt: String, text: Binding<String>, size: CGFloat, weight: Font.Weight, lines: Int) -> some View {
        TextField(prompt, text: text, axis: lines > 1 ? .vertical : .horizontal)
            .lineLimit(lines > 1 ? lines...lines : 1...1)
            .textFieldStyle(.plain)
            .font(BrandFonts.sans(size, weight: weight))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PopoverPalette.lineStrong, lineWidth: 1))
    }

    private func failureText(_ text: String) -> some View {
        Text(text)
            .font(BrandFonts.sans(12.5))
            .foregroundStyle(PopoverPalette.criticalText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step 2

    @ViewBuilder
    private var charter: some View {
        if let role {
            VStack(alignment: .leading, spacing: 16) {
                heading(2, "\(role.name)'s charter",
                        "This is the whole of \(role.pronoun.object): one file on your Mac. You can edit it any time.")
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        Text(installer.charter(for: role, model: model))
                            .font(BrandFonts.mono(11))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 0) {
                        CrewFace(face: role.face, name: role.name, size: 84)
                        Text(role.name)
                            .font(BrandFonts.sans(22, weight: .bold))
                            .tracking(-0.03 * 22)
                            .padding(.top, 12)
                        Text(role.title)
                            .font(BrandFonts.sans(13))
                            .foregroundStyle(PopoverPalette.secondary)
                        Text("Thinks with")
                            .font(BrandFonts.sans(11.5, weight: .semibold))
                            .foregroundStyle(PopoverPalette.secondary)
                            .padding(.top, 20)
                        Picker("Thinks with", selection: $model) {
                            ForEach(CrewInstaller.Model.allCases) { Text($0.label.prefix(1).uppercased() + $0.label.dropFirst()).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .padding(.top, 4)
                        Text("Runs on your Claude plan.")
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .padding(.top, 6)
                        Spacer(minLength: 16)
                        Text("Saved to \(TeamFormat.homePath(installer.charterURL(for: role))). The rule near the top stops \(role.pronoun.object) writing anywhere but \(role.pronoun.possessive) notebook. Nothing is uploaded.")
                            .font(BrandFonts.sans(12))
                            .foregroundStyle(PopoverPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let failure { failureText(failure).padding(.top, 8) }
                    }
                    .frame(width: 220, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: - Step 3

    @ViewBuilder
    private var done: some View {
        if let role {
            VStack(spacing: 0) {
                CrewFace(face: role.face, name: role.name, size: 84)
                    .overlay(alignment: .bottomTrailing) {
                        LineGlyph(data: HorizonGlyphs.check, size: 15, lineWidth: 2.4)
                            .foregroundStyle(PopoverPalette.successText)
                            .frame(width: 26, height: 26)
                            .background(PopoverPalette.successBackground, in: Circle())
                            .overlay(Circle().stroke(PopoverPalette.background, lineWidth: 3))
                            .offset(x: 2, y: 2)
                    }
                    .padding(.top, 10)
                Text("\(role.name)'s on the crew")
                    .font(BrandFonts.sans(20, weight: .bold))
                    .tracking(-0.03 * 20)
                    .padding(.top, 10)
                Text("\(role.pronoun.subject.prefix(1).uppercased() + role.pronoun.subject.dropFirst()) \(role.pronoun == .they ? "start" : "starts") with an empty notebook and \(role.pronoun == .they ? "fill" : "fills") it as \(role.pronoun.subject) \(role.pronoun == .they ? "work" : "works"). Say this in Claude Code:")
                    .font(BrandFonts.sans(13))
                    .foregroundStyle(PopoverPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    Text(role.firstJob)
                        .font(BrandFonts.sans(13.5, weight: .semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(role.firstJob, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        LineGlyph(data: copied ? HorizonGlyphs.check : HorizonGlyphs.copy, size: 14, lineWidth: 2)
                            .foregroundStyle(copied ? PopoverPalette.successText : PopoverPalette.text)
                            .frame(width: 28, height: 28)
                            .background(PopoverPalette.background, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied" : "Copy")
                    .accessibilityLabel(copied ? "Copied" : "Copy")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 14)
                Text("Claude Code picks up new crew in sessions you start from now on.")
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .frame(width: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            switch step {
            case .pick:
                quiet("Not now", action: close)
                Spacer()
                primary(choice == .someoneNew ? "Continue" : "Continue with \(role?.name ?? "")") {
                    guard let role else {
                        failure = "Give them a name and a job first."
                        return
                    }
                    if installer.isNameTaken(role) {
                        failure = CrewInstaller.Failure.nameTaken(role.id).errorDescription
                        return
                    }
                    go(.charter)
                }
            case .charter:
                secondary("Back") { go(.pick) }
                Spacer()
                primary("Hire \(role?.name ?? "")", action: hire)
            case .done:
                secondary("Hire another") {
                    newName = ""
                    newJob = ""
                    choice = CrewRole.featured.first { !isHired($0) }.map(Choice.role)
                        ?? CrewRole.more.first { !isHired($0) }.map(Choice.role) ?? .someoneNew
                    if case .role(let next) = choice { showsMore = CrewRole.more.contains(next) }
                    go(.pick)
                }
                Spacer()
                primary("Done", action: close)
            }
        }
    }

    private func go(_ next: Step) {
        failure = nil
        step = next
    }

    private func hire() {
        guard let role else { return }
        do {
            try installer.hire(role, model: model)
            onChange()
            go(.done)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .semibold))
                .foregroundStyle(PopoverPalette.onBrand)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(PopoverPalette.brand, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(PopoverPalette.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .medium))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.horizontal, 6)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}
