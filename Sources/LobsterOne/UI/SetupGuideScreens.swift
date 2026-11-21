import AppKit
import SwiftUI

/// The setup guide's screens after sign-in, one choice each. The window around them (progress,
/// Back, the buttons) is `SetupWizard`'s; these only show the choice and what it costs.
struct SetupGuideScreen: View {
    @ObservedObject var guide: SetupGuide
    /// Nil leaves the dictation screen saying it isn't available.
    var dictation: DictationController?

    var body: some View {
        switch guide.step {
        case .signIn: EmptyView()
        case .tools: ToolsScreen(guide: guide)
        case .sounds: SoundsScreen(guide: guide)
        case .dictation:
            if let dictation {
                DictationScreen(guide: guide, controller: dictation)
            } else {
                GuidePage(title: "Dictation", detail: "Not available in this build.", prop: .symbol("mic")) { EmptyView() }
            }
        case .alerts: AlertsScreen(guide: guide)
        case .screensaver: ScreensaverScreen(guide: guide)
        case .aws: AWSScreen(guide: guide)
        case .done: DoneScreen(guide: guide)
        }
    }
}

// MARK: - Page

/// What Garry holds up beside the headline: the step's own icon, from the Settings tab bar.
enum GarryProp {
    case glyph(AccentGlyph.Geometry)
    case symbol(String)
    case none
}

/// A headline, at most two lines on what it does and costs, Garry on his line, then the choice.
struct GuidePage<Content: View>: View {
    let title: String
    let detail: String
    var prop: GarryProp = .none
    /// Garry walks in place while something is switched on, and rests otherwise.
    var walking = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(BrandFonts.sans(22, weight: .semibold))
                        .tracking(-0.03 * 22)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(BrandFonts.sans(13.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GarryOnHisLine(walking: walking, prop: prop)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SetupWizard.sideMargin)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Garry standing on a short line, as on the About tab, with the step's icon at his shoulder.
struct GarryOnHisLine: View {
    var walking: Bool
    var prop: GarryProp = .none
    var scale: CGFloat = 0.72

    var body: some View {
        VStack(spacing: 0) {
            GarrySprite(walking: walking, scale: scale)
                .overlay(alignment: .topTrailing) { propView.offset(x: 24, y: -6) }
            Rectangle().fill(PopoverPalette.lineStrong).frame(width: 84 * scale + 20, height: 1)
        }
        // Room for the icon, so it stays inside the page margin.
        .padding(.trailing, hasProp ? 14 : 0)
        .accessibilityHidden(true)
    }

    private var hasProp: Bool {
        if case .none = prop { return false }
        return true
    }

    @ViewBuilder
    private var propView: some View {
        switch prop {
        case .glyph(let geometry):
            AccentGlyph(shape: geometry, size: 16)
                .frame(width: 28, height: 28)
                .background(PopoverPalette.blush, in: Circle())
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PopoverPalette.brand)
                .frame(width: 28, height: 28)
                .background(PopoverPalette.blush, in: Circle())
        case .none:
            EmptyView()
        }
    }
}

/// The Sand card every choice sits on.
struct GuideCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct GuideDivider: View {
    var body: some View { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
}

/// A row with a title, a line under it and a control at the end, as in Settings.
struct GuideRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var dot: Color?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                if let detail {
                    HStack(spacing: 6) {
                        if let dot {
                            Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                        }
                        Text(detail)
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// The app's switch, as Settings draws it.
struct GuideSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(PopoverPalette.brand)
            .accessibilityLabel(label)
    }
}

/// A quiet line under a card: what the choice writes or asks for.
struct GuideNote: View {
    let text: String
    var color: Color = PopoverPalette.tertiary

    init(_ text: String, color: Color = PopoverPalette.tertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(BrandFonts.sans(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
    }
}

// MARK: - Tools

private struct ToolsScreen: View {
    @ObservedObject var guide: SetupGuide

    var body: some View {
        GuidePage(title: "Your tools",
                  detail: "LobsterOne counts tokens in the coding tools you switch on. Each one gets a LobsterOne key in its settings file.",
                  prop: .glyph(SettingsTab.tools.glyph),
                  walking: !guide.tracked.isEmpty) {
            if let tools = guide.tools {
                GuideCard {
                    ForEach(Array(SetupGuide.Tool.allCases.enumerated()), id: \.element) { index, tool in
                        if index > 0 { GuideDivider() }
                        row(tool, tools[tool] ?? .init(installed: false, connected: false))
                    }
                }
                GuideNote("Switching a tool off takes the key out of its settings. Add tools later in Settings, Tools.")
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for coding tools on this Mac\u{2026}")
                        .font(BrandFonts.sans(13.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let problem = guide.problem {
                GuideNote(problem, color: PopoverPalette.criticalText)
            }
        }
    }

    private func row(_ tool: SetupGuide.Tool, _ presence: SetupGuide.ToolPresence) -> some View {
        let tracked = Binding(
            get: { guide.tracked.contains(tool) },
            set: { on in if on { guide.tracked.insert(tool) } else { guide.tracked.remove(tool) } })
        let detail: String
        if presence.connected {
            detail = "Connected"
        } else if presence.installed {
            detail = "Found on this Mac"
        } else {
            detail = "Not found on this Mac"
        }
        return HStack(spacing: 12) {
            Text(SettingsView.monogram(tool.title))
                .font(BrandFonts.mono(12.5, weight: .bold))
                .frame(width: 36, height: 36)
                .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text(detail)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if presence.available {
                GuideSwitch(label: "Track \(tool.title)", isOn: tracked)
            }
        }
        .opacity(presence.available ? 1 : 0.55)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Sounds

private struct SoundsScreen: View {
    @ObservedObject var guide: SetupGuide

    /// Six across fills the page's width; ten tiles make a row of six and a row of four.
    private let columns = Array(repeating: GridItem(.fixed(82), spacing: 18, alignment: .top), count: 6)

    var body: some View {
        GuidePage(title: "Sounds",
                  detail: "A short sound when a session starts, needs you, or finishes. Pick a pack, or keep it quiet.",
                  prop: .glyph(SettingsTab.sounds.glyph),
                  walking: guide.chosenPack != nil) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                NoSoundsTile(selected: guide.packID == nil) { guide.choosePack(nil) }
                ForEach(SoundPack.all) { pack in
                    SoundPackCover(pack: pack, selected: guide.packID == pack.id, play: { guide.playSample(pack) }) { guide.choosePack(pack.id) }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 2)

            // What the chosen pack is. A sample plays from the button that shows over a pack on hover.
            Group {
                Group {
                    if let pack = guide.chosenPack {
                        Text("\(pack.name). ").font(BrandFonts.sans(13, weight: .semibold))
                            + Text(pack.detail).font(BrandFonts.sans(13))
                    } else if guide.packID == SetupGuide.customPackID {
                        Text("Your own picks stay as they are, unless you choose a pack.")
                            .font(BrandFonts.sans(13))
                    } else {
                        Text("No sounds. Turn them on any time in Settings, Sounds.")
                            .font(BrandFonts.sans(13))
                    }
                }
                .foregroundStyle(PopoverPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 34)
        }
    }
}

/// "No sounds", drawn like a pack cover so it sits in the same row.
private struct NoSoundsTile: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PopoverPalette.secondary)
                    .frame(width: 76, height: 52)
                    .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(selected ? PopoverPalette.brand : Color.clear, lineWidth: 2)
                        .padding(-4))
                Text("No sounds")
                    .font(BrandFonts.sans(11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? PopoverPalette.brandText : (hovering ? PopoverPalette.text : PopoverPalette.secondary))
                    .lineLimit(1)
            }
            .frame(width: 82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("No sounds")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Dictation

private struct DictationScreen: View {
    @ObservedObject var guide: SetupGuide
    @ObservedObject var controller: DictationController
    @State private var microphones: [DictationMicrophones.Microphone] = []
    @State private var languages: [DictationLanguage.Option] = []
    @State private var selectedLanguage = DictationLanguage.selectedIdentifier ?? ""

    private var isAvailable: Bool { controller.availability == .available }

    var body: some View {
        GuidePage(title: "Dictation",
                  detail: "Hold a key, talk, and the words are typed where your cursor is. Speech is turned into text on this Mac.",
                  prop: .symbol("mic"),
                  walking: guide.dictationOn && isAvailable) {
            GuideCard {
                if let explanation = DictationController.unavailableExplanation(
                    controller.availability, osVersion: ProcessInfo.processInfo.operatingSystemVersion) {
                    GuideRow(title: "Not available on this Mac", detail: explanation) {
                        if controller.availability == .needsMacOS26 {
                            SettingsPill(title: "Update macOS", prominent: false) { DictationPermissions.openSoftwareUpdate() }
                        }
                    }
                } else {
                    GuideRow(title: "Dictate into any app",
                             detail: controller.availability == nil ? "Checking this Mac\u{2026}"
                                 : guide.dictationOn ? "Needs the two permissions below; macOS asks for any still missing."
                                 : "Off until you switch it on, here or in Settings.") {
                        GuideSwitch(label: "Dictate into any app", isOn: $guide.dictationOn)
                            .disabled(!isAvailable)
                    }
                    if guide.dictationOn && isAvailable {
                        GuideDivider()
                        GuideRow(title: "Shortcut", detail: "Hold it, speak, release. Change it in Settings.") {
                            Chip(text: controller.shortcut.displayName, quiet: false)
                        }
                        GuideDivider()
                        // One row for the microphone, as in Preferences: whether it is allowed, and
                        // once it is, which one. That leaves the page room for the language.
                        GuideRow(title: "Microphone", detail: microphoneText, dot: microphoneDot) {
                            switch controller.microphone {
                            case .allowed: microphonePicker
                            case .notAsked:
                                SettingsPill(title: "Allow", prominent: false) { controller.requestMicrophone() }
                                    .accessibilityLabel("Allow microphone access")
                            case .denied:
                                SettingsPill(title: "Open System Settings", prominent: false) { DictationPermissions.openMicrophoneSettings() }
                                    .accessibilityLabel("Open microphone settings")
                            }
                        }
                        GuideDivider()
                        GuideRow(title: "Language", detail: "The one language dictation listens for.") { languagePicker }
                        GuideDivider()
                        GuideRow(title: "Accessibility",
                                 detail: controller.accessibility ? "Allowed." : "Lets LobsterOne hear the key in other apps and paste.",
                                 dot: controller.accessibility ? PopoverPalette.dotActive : PopoverPalette.dotWaiting) {
                            if !controller.accessibility {
                                SettingsPill(title: "Open System Settings", prominent: false) { DictationPermissions.openAccessibilitySettings() }
                                    .accessibilityLabel("Open Accessibility settings")
                            }
                        }
                    }
                }
            }
            // Off: what it is, so there's something to decide on. On: the rows above take its place.
            if isAvailable && !guide.dictationOn {
                howItWorks
                GuideNote("Switching it on asks for microphone and Accessibility access; macOS asks at that moment.")
            }
        }
        .onAppear {
            controller.refreshPermissions()
            microphones = guide.env.microphones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
    }

    /// Three steps side by side, numbered, with no controls, so it reads as an explanation
    /// rather than as settings.
    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 0) {
            step(1, "Hold") {
                Chip(text: controller.shortcut.displayName, quiet: false)
            }
            Rectangle().fill(PopoverPalette.divider).frame(width: 1)
            step(2, "Talk") {
                Text("As you'd say it to someone.")
            }
            Rectangle().fill(PopoverPalette.divider).frame(width: 1)
            step(3, "Let go") {
                Text("The words are typed where your cursor is.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How it works: hold \(controller.shortcut.displayName), talk, let go, and the words are typed where your cursor is.")
    }

    private func step<Detail: View>(_ number: Int, _ title: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(BrandFonts.sans(12, weight: .bold))
                    .foregroundStyle(PopoverPalette.brandText)
                    .frame(width: 22, height: 22)
                    .background(PopoverPalette.blush, in: Circle())
                Text(title)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
            }
            detail()
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// System default first, then each microphone connected now; saved when the screen is confirmed.
    private var microphonePicker: some View {
        Picker("Microphone", selection: $guide.microphoneUID) {
            Text(guide.env.systemMicrophoneName().map { "System default (\($0))" } ?? "System default").tag("")
            Divider()
            ForEach(microphones) { Text($0.name).tag($0.uid) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Microphone")
    }

    /// The model hears one language at a time, so this is how a French speaker on an English
    /// Mac gets French. Applied at once, like the same choice in Preferences.
    private var languagePicker: some View {
        Picker("Language", selection: Binding(
            get: { selectedLanguage },
            set: { identifier in
                selectedLanguage = identifier
                controller.setLanguage(identifier.isEmpty ? nil : identifier)
            }
        )) {
            Text("System (\(DictationLanguage.name(for: Locale.current.identifier)))").tag("")
            Divider()
            ForEach(languages) { Text($0.name).tag($0.identifier) }
            if !selectedLanguage.isEmpty, !languages.contains(where: { $0.identifier == selectedLanguage }) {
                Text(DictationLanguage.name(for: selectedLanguage)).tag(selectedLanguage)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Language")
        .task { if languages.isEmpty { languages = await DictationLanguage.supported() } }
    }

    private var microphoneDot: Color {
        switch controller.microphone {
        case .allowed: PopoverPalette.dotActive
        case .denied: PopoverPalette.critical
        case .notAsked: PopoverPalette.dotWaiting
        }
    }

    private var microphoneText: String {
        switch controller.microphone {
        case .allowed: "Allowed."
        case .denied: "Off for LobsterOne, so it can't hear you."
        case .notAsked: "Not asked yet. Turning dictation on asks."
        }
    }
}

// MARK: - Alerts

private struct AlertsScreen: View {
    @ObservedObject var guide: SetupGuide

    var body: some View {
        GuidePage(title: "Usage cap alerts",
                  detail: "A notification when your pace will hit the session or weekly cap before it resets.",
                  prop: .glyph(SettingsTab.notifications.glyph),
                  walking: guide.paceAlertsOn) {
            GuideCard {
                GuideRow(title: "Alert me", detail: "At most one per cap each time it resets.") {
                    GuideSwitch(label: "Usage cap alerts", isOn: $guide.paceAlertsOn)
                }
                GuideDivider()
                GuideRow(title: "macOS notifications", detail: permissionText, dot: permissionDot) {
                    if guide.notificationPermission == .denied {
                        SettingsPill(title: "Open System Settings", prominent: false) {
                            let id = Bundle.main.bundleIdentifier ?? "com.lobsterone.mac"
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .accessibilityLabel("Open notification settings")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What one looks like")
                    .font(BrandFonts.sans(13, weight: .medium))
                    .foregroundStyle(PopoverPalette.secondary)
                    .padding(.leading, 2)
                AlertPreview(lifted: false)
            }
            .opacity(guide.paceAlertsOn ? 1 : 0.5)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await guide.refreshNotificationPermission() }
        }
    }

    private var permissionText: String {
        switch guide.notificationPermission {
        case .allowed: "Allowed."
        case .denied: "Off for LobsterOne, so alerts can't appear."
        case .notAsked: guide.paceAlertsOn ? "Not asked yet. Continuing asks macOS once." : "Not asked yet."
        case .unavailable: "Not available in this build."
        case nil: "Checking\u{2026}"
        }
    }

    private var permissionDot: Color {
        switch guide.notificationPermission {
        case .allowed: PopoverPalette.dotActive
        case .denied: PopoverPalette.critical
        default: PopoverPalette.dotWaiting
        }
    }
}

// MARK: - Screensaver

private struct ScreensaverScreen: View {
    @ObservedObject var guide: SetupGuide

    var body: some View {
        GuidePage(title: "Screensaver",
                  detail: "Your day in tokens, on the screen while you're away. Pick a design; you can switch any time.",
                  prop: .glyph(SettingsTab.screensaver.glyph),
                  walking: guide.screensaverAvailable) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(ScreensaverStyle.allCases, id: \.self) { style in tile(style) }
            }
            .padding(.top, 4)
            .allowsHitTesting(guide.screensaverAvailable)
            .opacity(guide.screensaverAvailable ? 1 : 0.45)

            GuideCard {
                if guide.screensaverAvailable {
                    GuideRow(title: guide.screensaverStyle.title, detail: guide.screensaverStyle.summary) { EmptyView() }
                } else {
                    GuideRow(title: "Not in this build", detail: "The screensaver isn't included in this build, so there's nothing to install.") { EmptyView() }
                }
            }

            if guide.screensaverAvailable {
                GuideNote(guide.screensaverInstalled
                          ? "Installed. Continuing switches it to this design."
                          : "Installing copies it to your Screen Savers folder, then opens System Settings so you can pick it.")
            }
            if let problem = guide.problem {
                GuideNote(problem, color: PopoverPalette.criticalText)
            }
        }
    }

    private func tile(_ style: ScreensaverStyle) -> some View {
        let chosen = style == guide.screensaverStyle
        return Button { guide.screensaverStyle = style } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = ScreensaverInstaller.previewImage(style) {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Rectangle().fill(PopoverPalette.card)
                    }
                }
                .frame(width: 124, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(chosen ? PopoverPalette.brand : Color.clear, lineWidth: 2)
                    .padding(-4))
                Text(style.title)
                    .font(BrandFonts.sans(12.5, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? PopoverPalette.brandText : PopoverPalette.secondary)
                    .lineLimit(1)
            }
            .frame(width: 128)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title). \(style.summary)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: - AWS

private struct AWSScreen: View {
    @ObservedObject var guide: SetupGuide

    var body: some View {
        GuidePage(title: "AWS costs",
                  detail: "If you run things on AWS: this month's spend per account, next to your Claude usage.",
                  prop: .glyph(SettingsTab.aws.glyph)) {
            HStack(alignment: .top, spacing: 20) {
                AWSExample()
                    .frame(width: 330)
                VStack(alignment: .leading, spacing: 14) {
                    fact("AWS Cost Explorer bills $0.01 a refresh, about once a day.")
                    fact("Keys and figures stay on this Mac.")
                    Text(guide.awsConnected ? "Already connected. Manage it in Settings, AWS."
                         : "Set up AWS opens Settings on the AWS tab when this guide ends.")
                        .font(BrandFonts.sans(12))
                        .foregroundStyle(guide.awsConnected ? PopoverPalette.secondary : PopoverPalette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fact(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            LineGlyph(data: HorizonGlyphs.check, size: 13, lineWidth: 2.2)
                .foregroundStyle(PopoverPalette.seagrass)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text)
                .font(BrandFonts.sans(13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the AWS page looks like, drawn with its own pieces from made-up figures and marked
/// as an example. Static: no monitor, no network, nothing read from disk.
private struct AWSExample: View {
    private static let accounts = [
        AccountCost(accountId: "000000000001", name: "Acme production", thisMonth: 214.40, lastMonth: 301.10, forecast: 388.00),
        AccountCost(accountId: "000000000002", name: "Acme staging", thisMonth: 48.90, lastMonth: 92.30, forecast: 86.00),
        AccountCost(accountId: "000000000003", name: "Sandbox", thisMonth: 6.15, lastMonth: 14.80, forecast: 11.00),
    ]
    private static let currency = "USD"

    private var month: String { CostMath.month(Date()) }
    private var total: SpendTrend {
        SpendTrend(thisMonth: Self.accounts.map(\.thisMonth).reduce(0, +),
                   lastMonth: Self.accounts.map(\.lastMonth).reduce(0, +),
                   forecast: Self.accounts.compactMap(\.forecast).reduce(0, +))
    }

    var body: some View {
        let lastShort = CostFormat.monthName(month, offset: -1, short: true) ?? "last month"
        let context = AccountCostRow.Context(
            currency: Self.currency,
            lastMonthName: CostFormat.monthName(month, offset: -1) ?? "Last month",
            lastMonthShortName: lastShort,
            daysInMonth: nil,
            total: total.thisMonth)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("3 accounts \u{00B7} \(CostFormat.monthName(month) ?? "This month")")
                        .font(BrandFonts.sans(13))
                        .foregroundStyle(PopoverPalette.secondary)
                    Spacer(minLength: 4)
                    Chip(text: "Example")
                }
                HStack(spacing: 10) {
                    Text(CostFormat.money(total.thisMonth, currency: Self.currency))
                        .font(BrandFonts.sans(22, weight: .semibold))
                    if let change = total.change {
                        CostTrendPill(change: change, rising: total.isRising, suffix: " vs \(lastShort)")
                    }
                }
                .padding(.top, 4)
                CostSpendBar(trend: total, height: 7)
                    .padding(.top, 9)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ForEach(Self.accounts) { account in
                GuideDivider()
                AccountCostRow(account: account, context: context, alertLimit: nil, setAlertLimit: { _ in },
                               isExpanded: false, toggle: {}, openBilling: {})
            }
        }
        .background(PopoverPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // A picture of the page, not the page: nothing in it responds.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example of the AWS page, with made-up accounts and amounts")
    }
}

// MARK: - Done

private struct DoneScreen: View {
    @ObservedObject var guide: SetupGuide

    private let steps: [SetupGuide.Step] = [.tools, .sounds, .dictation, .alerts, .screensaver, .aws]

    var body: some View {
        GuidePage(title: "All set",
                  detail: "Garry's in your menu bar. Everything here can be changed in Settings.",
                  walking: true) {
            GuideCard {
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    if index > 0 { GuideDivider() }
                    row(step, guide.outcomes[step] ?? .skipped)
                }
            }
            GuideNote("LobsterOne opens when you log in to your Mac. Turn that off in Settings, Preferences.")
        }
    }

    private func row(_ step: SetupGuide.Step, _ outcome: SetupGuide.Outcome) -> some View {
        let value: String
        switch outcome {
        case .on(let text), .off(let text), .failed(let text): value = text
        case .skipped: value = "Not now"
        }
        return HStack(spacing: 12) {
            mark(outcome)
            Text(step.summaryTitle)
                .font(BrandFonts.sans(13.5, weight: .semibold))
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(BrandFonts.sans(13))
                .foregroundStyle(outcome == .skipped ? PopoverPalette.tertiary
                                 : { if case .failed = outcome { return PopoverPalette.criticalText } else { return PopoverPalette.secondary } }())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// A tick for on, a quiet dot for off or not now, a warning when it didn't take.
    @ViewBuilder
    private func mark(_ outcome: SetupGuide.Outcome) -> some View {
        ZStack {
            switch outcome {
            case .on:
                Circle().fill(PopoverPalette.seagrass)
                LineGlyph(data: HorizonGlyphs.check, size: 12, lineWidth: 2.4)
                    .foregroundStyle(PopoverPalette.onBrand)
            case .failed:
                Circle().fill(PopoverPalette.warningBackground)
                LineGlyph(data: HorizonGlyphs.warning, size: 12, lineWidth: 2.2)
                    .foregroundStyle(PopoverPalette.warningText)
            case .off, .skipped:
                Circle().strokeBorder(PopoverPalette.lineStrong, lineWidth: 1.5)
                Circle().fill(PopoverPalette.tertiary).frame(width: 5, height: 5)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
