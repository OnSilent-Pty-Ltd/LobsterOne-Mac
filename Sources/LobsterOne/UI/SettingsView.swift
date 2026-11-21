import AppKit
import AVFoundation
import Combine
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// The Settings window's tabs, in tab-bar order. ⌘1 to ⌘9 reach the first nine, in this order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case preferences, notifications, sounds, tools, screensaver, account, aws, diagnostics, logs, about

    /// The app's one window size. One height for every tab, so the window doesn't jump when you
    /// switch; a page taller than this scrolls.
    static let windowWidth = AppWindow.size.width
    static let windowHeight = AppWindow.size.height

    /// The tabs along the top. Diagnostics and Logs are reached from About.
    static let shown: [SettingsTab] = allCases.filter { !$0.isUnderAbout }

    /// Pages opened from About, not from the bar.
    var isUnderAbout: Bool { self == .diagnostics || self == .logs }

    var id: Self { self }

    var title: String {
        switch self {
        case .preferences: "Preferences"
        case .notifications: "Notifications"
        case .sounds: "Sounds"
        case .tools: "Tools"
        case .screensaver: "Screensaver"
        case .account: "Account"
        case .aws: "AWS"
        case .diagnostics: "Diagnostics"
        case .logs: "Logs"
        case .about: "About"
        }
    }

    /// The digit after ⌘ that opens this tab, for the first nine.
    var shortcutNumber: Int? {
        guard let index = Self.shown.firstIndex(of: self) else { return nil }
        return index < 9 ? index + 1 : nil
    }

    /// Settings you change, then the tab you visit when something's off.
    var isHelp: Bool { self == .about }

    /// Icons in the app's line-and-accent style (24 x 24): outline in the text colour, one
    /// part in Lobster.
    var glyph: AccentGlyph.Geometry {
        switch self {
        case .preferences:
            AccentGlyph.Geometry(
                outline: "M4 8h16M4 16h16",
                accentFill: "M11.4 8a2.4 2.4 0 1 1-4.8 0a2.4 2.4 0 1 1 4.8 0ZM17.4 16a2.4 2.4 0 1 1-4.8 0a2.4 2.4 0 1 1 4.8 0Z")
        case .notifications:
            AccentGlyph.Geometry(
                outline: "M6 16.5V11a6 6 0 0 1 9-5.2M18 10.5v6l1.5 2h-15l1.5-2M10 20.5a2 2 0 0 0 4 0",
                accentFill: "M20.6 6.2a2.6 2.6 0 1 1-5.2 0a2.6 2.6 0 1 1 5.2 0Z")
        case .sounds:
            AccentGlyph.Geometry(
                outline: "M4 9.5h3.5L12 5.5v13l-4.5-4H4Z",
                accentLine: "M15.5 9.5a3.5 3.5 0 0 1 0 5M18 7a7 7 0 0 1 0 10")
        case .tools:
            AccentGlyph.Geometry(
                outline: "M4 6.5A1.5 1.5 0 0 1 5.5 5h13A1.5 1.5 0 0 1 20 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5Z",
                accentLine: "M8 10l2.5 2L8 14M12.5 14H16")
        case .screensaver:
            AccentGlyph.Geometry(
                outline: "M3.5 6A1.5 1.5 0 0 1 5 4.5h14A1.5 1.5 0 0 1 20.5 6v9a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 15ZM9 20h6M12 16.5V20",
                accentLine: "M8.5 8v2.5M12 7.5v5M15.5 9v2.5")
        case .account:
            AccentGlyph.Geometry(
                outline: "M15.5 8.5a3.5 3.5 0 1 1-7 0a3.5 3.5 0 1 1 7 0Z",
                accentLine: "M5 19.5c1-3.5 3.8-5 7-5s6 1.5 7 5")
        case .aws:
            AccentGlyph.Geometry(
                outline: "M7.5 18h10a3.5 3.5 0 0 0 .4-6.98A5.5 5.5 0 0 0 7.3 10.1A4 4 0 0 0 7.5 18Z",
                accentLine: "M9.5 15.5l2-2 1.5 1.5 2.5-2.5")
        case .diagnostics:
            AccentGlyph.health
        case .logs:
            AccentGlyph.Geometry(
                outline: "M6 3.5h8l4 4v13H6ZM14 3.5v4h4",
                accentLine: "M9 11.5h6M9 15h6M9 18h3.5")
        case .about:
            AccentGlyph.Geometry(
                outline: "M20.5 12a8.5 8.5 0 1 1-17 0a8.5 8.5 0 1 1 17 0Z",
                accentFill: "M13.1 7.9a1.1 1.1 0 1 1-2.2 0a1.1 1.1 0 1 1 2.2 0Z",
                accentLine: "M12 11v5.5")
        }
    }
}

/// Which tab Settings shows. Owned by the app, so the menu can open Settings on a given tab
/// and the window title can follow it.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .preferences
}

/// What the Account tab shows; read by the app when Settings opens.
struct SettingsAccount {
    var email: String?
    var claudePlan: String?
    var keyPrefix: String?
}

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter
    @State private var visited: Set<SettingsTab> = []
    @State private var isLoginItem = SMAppService.mainApp.status == .enabled
    @State private var paceAlerts = PaceNotifier.isEnabled
    @State private var notificationPermission: PaceNotifier.Permission = .allowed
    @State private var townInvites = TownInviteNotifier.isEnabled
    @State private var awsCostAlerts = CostAlertNotifier.isEnabled
    @AppStorage(SessionDetailsPreference.key) private var sendSessionDetails = true
    @State private var sourceStatuses: [SourceStatus]
    @State private var isAddingTool = false
    @State private var isDetectingTools = false
    @State private var addToolError: String?
    @State private var unconfiguredSources: [ConfigService.ConfiguredSource] = []
    @State private var screensaverInstalled = ScreensaverInstaller.isInstalled
    @State private var screensaverError: String?
    @State private var screensaverStyle = ScreensaverInstaller.chosenStyle
    @State private var screensaverSystem = ScreensaverSystemState(choice: .unknown, idleSeconds: nil)
    @State private var screensaverVersion: String?

    let configService: ConfigService
    let onDisconnect: (String) -> Void
    let onAddTool: (String) async throws -> Void
    let onRefreshSources: () async -> [SourceStatus]
    var onScreensaverChanged: (Bool) -> Void = { _ in }
    var onTownInvitesChanged: (Bool) -> Void = { _ in }
    var onScreensaverStyleChanged: (ScreensaverStyle) -> Void = { _ in }
    var account = SettingsAccount()
    var onSignOut: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    /// The AWS tab's connection and cost monitor.
    var awsCosts: AWSCostService?
    /// The Diagnostics tab's content; it needs the app's check and fix hooks.
    var diagnostics: DiagnosticsView?
    /// Hold-to-talk dictation, owned by the app. Nil leaves the Dictation section out.
    var dictation: DictationController?
    /// Reopens the setup guide at its first choice. Nil leaves the row out.
    var onRunSetupGuide: (() -> Void)?
    @State private var isSendingTest = false
    @State private var testResult: String?

    init(router: SettingsRouter,
         sourceStatuses: [SourceStatus],
         configService: ConfigService = ConfigService(),
         onDisconnect: @escaping (String) -> Void,
         onAddTool: @escaping (String) async throws -> Void,
         onRefreshSources: @escaping () async -> [SourceStatus]) {
        self.router = router
        self._sourceStatuses = State(initialValue: sourceStatuses)
        self.configService = configService
        self.onDisconnect = onDisconnect
        self.onAddTool = onAddTool
        self.onRefreshSources = onRefreshSources
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsTabBar(selection: $router.tab)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            }

            // A tab is built the first time it's opened and then kept, so Diagnostics doesn't
            // re-run its checks and the log keeps its scroll position when you switch back.
            ZStack(alignment: .topLeading) {
                ForEach(SettingsTab.allCases.filter(visited.contains), id: \.self) { tab in
                    page(tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(tab == router.tab ? 1 : 0)
                        .allowsHitTesting(tab == router.tab)
                        .accessibilityHidden(tab != router.tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsTab.windowWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .sheet(isPresented: $isAddingTool) {
            addToolSheet
        }
        .onAppear { visited.insert(router.tab) }
        .onChange(of: router.tab) { _, tab in
            visited.insert(tab)
        }
        // Re-check when Settings opens and when coming back from System Settings
        .task { notificationPermission = await PaceNotifier.permission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationPermission = await PaceNotifier.permission() }
        }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .preferences: scrolling { preferencesTab }
        case .notifications: scrolling { notificationsTab }
        case .sounds: scrolling { SoundsPane() }
        case .tools: scrolling { toolsTab }
        case .screensaver: scrolling { screensaverTab }
        case .account: scrolling { accountTab }
        case .aws:
            if let awsCosts {
                scrolling {
                    AWSSettingsPane(service: awsCosts, monitor: awsCosts.monitor) { router.tab = .notifications }
                }
            }
        case .diagnostics:
            if let diagnostics {
                VStack(spacing: 0) {
                    backToAbout
                    diagnostics.padding(.top, 8)
                }
            }
        case .logs:
            VStack(spacing: 0) {
                backToAbout
                DebugLogView()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
        case .about: scrolling { aboutTab }
        }
    }

    /// Diagnostics and Logs open from About, so each has a way back to it.
    private var backToAbout: some View {
        HStack {
            Button { router.tab = .about } label: {
                HStack(spacing: 4) {
                    LineGlyph(data: HorizonGlyphs.chevronDown, size: 14, lineWidth: 2).rotationEffect(.degrees(90))
                    Text("About")
                }
                .font(BrandFonts.sans(13, weight: .semibold))
                .foregroundStyle(PopoverPalette.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to About")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    /// A page that scrolls when it is taller than the window.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 26)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Preferences

    private var preferencesTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("General") {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at login")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("Starts when you sign in to your Mac.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                        }
                        Spacer(minLength: 0)
                        Toggle("Launch at login", isOn: $isLoginItem)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(PopoverPalette.brand)
                            .onChange(of: isLoginItem) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    isLoginItem = !newValue
                                }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if let onRunSetupGuide {
                        rowDivider
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Run the setup guide again")
                                    .font(BrandFonts.sans(14.5, weight: .semibold))
                                Text("Tools, sounds, dictation, alerts and the screensaver, one at a time.")
                                    .font(BrandFonts.sans(12.5))
                                    .foregroundStyle(PopoverPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            PillButton(title: "Open guide", prominent: false) { onRunSetupGuide() }
                                .accessibilityLabel("Run the setup guide again")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }

            if let dictation {
                section("Dictation") {
                    DictationSettingsRows(controller: dictation, isShown: router.tab == .preferences)
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Alerts") {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usage cap alerts")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("Notifies you when your pace will hit the session or weekly cap before it resets.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Toggle("Usage cap alerts", isOn: $paceAlerts)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(PopoverPalette.brand)
                            .onChange(of: paceAlerts) { _, newValue in
                                PaceNotifier.isEnabled = newValue
                                if newValue {
                                    Task {
                                        await PaceNotifier.requestPermission()
                                        notificationPermission = await PaceNotifier.permission()
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, paceAlerts && notificationPermission.needsAction ? 8 : 12)

                    if paceAlerts && notificationPermission.needsAction {
                        notificationPermissionNotice
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }

                    rowDivider

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Town invites")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("Notifies you when someone you know asks you into the harbour town. Never from 8 pm to 9 am, at most 3 a day.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Toggle("Town invites", isOn: $townInvites)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(PopoverPalette.brand)
                            .onChange(of: townInvites) { _, newValue in
                                TownInviteNotifier.isEnabled = newValue
                                onTownInvitesChanged(newValue)
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    rowDivider

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AWS cost alerts")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("Notifies you when an AWS account passes the monthly amount you set for it in the AWS tab.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Toggle("AWS cost alerts", isOn: $awsCostAlerts)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(PopoverPalette.brand)
                            .onChange(of: awsCostAlerts) { _, newValue in
                                CostAlertNotifier.isEnabled = newValue
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            section("What an alert looks like") {
                VStack(alignment: .leading, spacing: 12) {
                    AlertPreview()
                    HStack(spacing: 10) {
                        PillButton(title: isSendingTest ? "Sending\u{2026}" : "Send a test alert", prominent: false) {
                            Task {
                                isSendingTest = true
                                testResult = await PaceNotifier.sendTest()
                                notificationPermission = await PaceNotifier.permission()
                                isSendingTest = false
                            }
                        }
                        .disabled(isSendingTest)
                        if let testResult {
                            Text(testResult)
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(notificationPermission == .allowed ? PopoverPalette.secondary : PopoverPalette.criticalText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("macOS") {
                notificationStatusRow
            }
        }
    }

    /// Where macOS stands on letting LobsterOne notify, with a way to change it.
    private var notificationStatusRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notification permission")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(notificationPermission == .allowed ? PopoverPalette.dotActive
                              : notificationPermission == .denied ? PopoverPalette.critical : PopoverPalette.dotWaiting)
                        .frame(width: 7, height: 7)
                    Text(notificationPermissionText)
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            PillButton(title: "Open System Settings", prominent: false) {
                let id = Bundle.main.bundleIdentifier ?? "com.lobsterone.mac"
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var notificationPermissionText: String {
        switch notificationPermission {
        case .allowed: return "Allowed. Banner style and sounds are set in System Settings."
        case .denied: return "Off for LobsterOne, so alerts can't appear."
        case .notAsked: return "Not asked yet. Turning on an alert asks."
        case .unavailable: return "Not available in this build."
        }
    }

    // MARK: Tools

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Connected tools") {
                VStack(spacing: 0) {
                    if sourceStatuses.isEmpty {
                        VStack(spacing: 8) {
                            GarrySprite(walking: false, scale: 1)
                            Text("No tools connected yet")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("Connect Claude Code, Codex or Mistral Vibe and Garry starts counting.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    } else {
                        ForEach(sourceStatuses) { source in
                            sourceRow(source)
                            rowDivider
                        }
                    }
                    if sourceStatuses.isEmpty { rowDivider }

                    SettingsRowButton(action: detectTools) {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(PopoverPalette.brand)
                            Text("Add tool")
                                .font(BrandFonts.sans(14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
            }

            if let error = addToolError {
                Text(error)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            addToolError = nil
                        }
                    }
            }

            section("What Claude Code sends") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session openings and file paths")
                            .font(BrandFonts.sans(14.5, weight: .semibold))
                        Text(sendSessionDetails
                             ? "The first 500 characters of each session's first prompt, its title and the files it touches, so you can sort your tokens by project and client. Only you see them."
                             : "Off: only usage numbers, the project folder and the branch are sent. What was sent before stays until you ask privacy@lobsterone.ai to delete it.")
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Send session openings and file paths", isOn: $sendSessionDetails)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(PopoverPalette.brand)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: Screensaver

    /// One LobsterOne screensaver with four designs, so the tab answers two things apart: is it
    /// set up (installed, chosen in macOS, when it starts), and which design shows.
    private var screensaverTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            if screensaverAvailable {
                VStack(spacing: 0) {
                    installedStep
                    rowDivider
                    chosenStep
                    rowDivider
                    timingStep
                    if let screensaverError {
                        rowDivider
                        Text(screensaverError)
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.criticalText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                section("Design") {
                    VStack(spacing: 0) {
                        ForEach(Array(ScreensaverStyle.allCases.enumerated()), id: \.element) { index, style in
                            if index > 0 { rowDivider }
                            designRow(style)
                        }
                    }
                }
            } else {
                Text("The screensaver isn't included in this build.")
                    .font(BrandFonts.sans(13.5))
                    .foregroundStyle(PopoverPalette.secondary)
            }
        }
        // The person changes the choice and the timing in System Settings, so look again
        // whenever the tab comes up or the app comes back to the front.
        .onAppear(perform: refreshScreensaver)
        .onChange(of: router.tab) { _, tab in
            if tab == .screensaver { refreshScreensaver() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreensaver()
        }
    }

    #if DEBUG
    /// Stands in for the real install and System Settings state, for offscreen renders in tests.
    static var screensaverStateOverride: (installed: Bool, version: String?, system: ScreensaverSystemState)?
    #endif

    private var screensaverAvailable: Bool {
        #if DEBUG
        if Self.screensaverStateOverride != nil { return true }
        #endif
        return ScreensaverInstaller.bundledURL != nil || screensaverInstalled
    }

    private var screensaverActive: Bool {
        screensaverInstalled && screensaverSystem.choice == .lobsterOne
    }

    private var installedStep: some View {
        Group {
            if screensaverInstalled {
                let version = screensaverVersion.map { "Version \($0). " } ?? ""
                checklistStep(.done, title: "Installed", detail: "\(version)Updates with the app.") {
                    DisconnectButton(title: "Remove") {
                        run { try ScreensaverInstaller.remove() }
                    }
                    .accessibilityLabel("Remove the screensaver")
                }
            } else {
                checklistStep(.todo(1), title: "Not installed", detail: "Takes a few seconds.") {
                    PillButton(title: "Install with \(screensaverStyle.title)", prominent: true) { install() }
                        .accessibilityLabel("Install the screensaver with the \(screensaverStyle.title) design")
                }
            }
        }
    }

    private var chosenStep: some View {
        let mark: StepMark
        let title: String
        let detail: String?
        let pickIt = "Pick LobsterOne at the bottom of the list, under Other."
        switch screensaverSystem.choice {
        case .lobsterOne where screensaverInstalled:
            (mark, title, detail) = (.done, "LobsterOne is your screensaver", nil)
        case .unknown:
            (mark, title, detail) = (.neutral, "Check that LobsterOne is chosen in System Settings", pickIt)
        case .other(let name):
            (mark, title, detail) = (.todo(2), "Not your screensaver yet", "macOS is using \(name ?? "another screensaver"). \(pickIt)")
        case .lobsterOne:
            // Still chosen in macOS after a remove: it has nothing to show until it's back.
            (mark, title, detail) = (.todo(2), "Not your screensaver yet", "Install it, then \(pickIt.prefix(1).lowercased() + pickIt.dropFirst())")
        }
        return checklistStep(mark, title: title, detail: detail, dimmed: !screensaverInstalled) {
            if !screensaverActive {
                PillButton(title: "Open System Settings", prominent: screensaverInstalled) {
                    ScreensaverInstaller.openScreenSaverSettings()
                }
                .disabled(!screensaverInstalled)
                .accessibilityLabel("Open Screen Saver in System Settings")
            }
        }
    }

    private var timingStep: some View {
        let idle = screensaverSystem.idleSeconds
        let timeSet = (idle ?? 0) > 0
        return checklistStep(timeSet && screensaverActive ? .done : .neutral,
                             title: ScreensaverSystemState.timingTitle(idle),
                             detail: idle == 0 ? "Set a time in System Settings, Lock Screen." : "Set in System Settings, Lock Screen.",
                             dimmed: !screensaverInstalled) {
            PillButton(title: "Preview now", prominent: false) { ScreensaverInstaller.startNow() }
                .disabled(!screensaverInstalled)
                .accessibilityLabel("Start the screensaver now")
        }
    }

    private enum StepMark: Equatable {
        case done, todo(Int), neutral
    }

    /// One line of the checklist: a tick, a step number or a quiet dot; what's true; and the
    /// action that fixes it, if any.
    private func checklistStep<Trailing: View>(_ mark: StepMark, title: String, detail: String?,
                                               dimmed: Bool = false,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            stepMark(mark)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFonts.sans(13.5, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(mark == .done ? "Done: \(title)" : title)
            trailing()
        }
        .opacity(dimmed ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
    }

    private func stepMark(_ mark: StepMark) -> some View {
        ZStack {
            switch mark {
            case .done:
                Circle().fill(PopoverPalette.seagrass)
                LineGlyph(data: HorizonGlyphs.check, size: 13, lineWidth: 2.4)
                    .foregroundStyle(PopoverPalette.onBrand)
            case .todo(let number):
                Circle().strokeBorder(PopoverPalette.lineStrong, lineWidth: 1.5)
                Text("\(number)")
                    .font(BrandFonts.sans(12, weight: .bold))
                    .foregroundStyle(PopoverPalette.tertiary)
            case .neutral:
                Circle().strokeBorder(PopoverPalette.lineStrong, lineWidth: 1.5)
                Circle().fill(PopoverPalette.tertiary).frame(width: 6, height: 6)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// One design: a radio, a still of it, one sentence, and either "Showing" or a way to show it.
    private func designRow(_ style: ScreensaverStyle) -> some View {
        let chosen = style == screensaverStyle
        let showing = chosen && screensaverInstalled
        return HStack(spacing: 14) {
            ZStack {
                if chosen {
                    Circle().strokeBorder(PopoverPalette.brand, lineWidth: 5)
                } else {
                    Circle().fill(PopoverPalette.background)
                    Circle().strokeBorder(PopoverPalette.lineStrong, lineWidth: 1.5)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Group {
                if let image = ScreensaverInstaller.previewImage(style) {
                    Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle().fill(PopoverPalette.background)
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(chosen ? PopoverPalette.brand : .clear, lineWidth: 2)
                    .padding(-4))
            .padding(.vertical, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(style.title)
                        .font(BrandFonts.sans(14.5, weight: .semibold))
                    if showing { Chip(text: "Showing") }
                }
                Text(style.summary)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(style.title)\(showing ? ", showing" : ""). \(style.summary)")
            .accessibilityAddTraits(chosen ? .isSelected : [])

            // Before install, picking a row only chooses the design; the Install step above
            // installs with it, so the rows don't repeat four identical install buttons.
            if screensaverInstalled && !chosen {
                PillButton(title: "Show this design", prominent: false) { choose(style, install: false) }
                    .accessibilityLabel("Show \(style.title)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !chosen { choose(style, install: false) } }
    }

    private func choose(_ style: ScreensaverStyle, install: Bool) {
        screensaverStyle = style
        onScreensaverStyleChanged(style)
        if install { self.install() }
    }

    /// Installs, then opens the picker in System Settings unless LobsterOne is already chosen there.
    private func install() {
        run { try ScreensaverInstaller.install() }
        if screensaverInstalled && !screensaverActive { ScreensaverInstaller.openScreenSaverSettings() }
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
            screensaverError = nil
        } catch {
            screensaverError = error.localizedDescription
        }
        refreshScreensaver()
        onScreensaverChanged(screensaverInstalled)
    }

    private func refreshScreensaver() {
        #if DEBUG
        if let override = Self.screensaverStateOverride {
            screensaverInstalled = override.installed
            screensaverSystem = override.system
            screensaverVersion = override.version
            return
        }
        #endif
        screensaverInstalled = ScreensaverInstaller.isInstalled
        screensaverSystem = .read()
        screensaverVersion = screensaverInstalled ? ScreensaverInstaller.installedDisplayVersion : nil
    }

    // MARK: Account

    private var accountTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Text(String((account.email ?? "?").prefix(1)).uppercased())
                    .font(BrandFonts.sans(22, weight: .semibold))
                    .foregroundStyle(PopoverPalette.brandText)
                    .frame(width: 52, height: 52)
                    .background(PopoverPalette.blush, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email ?? "Signed in")
                        .font(BrandFonts.sans(17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let plan = account.claudePlan {
                            Chip(text: "Claude \(plan)")
                        }
                        Chip(text: "\(sourceStatuses.count) \(sourceStatuses.count == 1 ? "tool" : "tools") connected", quiet: true)
                    }
                }
                Spacer(minLength: 8)
                PillButton(title: "Manage account", prominent: false) {
                    NSWorkspace.shared.open(URL(string: "\(Constants.appURL)/settings/account")!)
                }
            }
            .padding(16)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))

            section("This Mac") {
                VStack(spacing: 0) {
                    infoRow("Reporting key", account.keyPrefix.map { "\($0)\u{2026}" } ?? "None", mono: true)
                    rowDivider
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your numbers, in full")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            Text("History, boards and badges live on the dashboard.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                        }
                        Spacer(minLength: 8)
                        PillButton(title: "Open dashboard", prominent: true) {
                            NSWorkspace.shared.open(URL(string: "\(Constants.appURL)/dashboard")!)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            section("Sign out") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign out of this Mac")
                            .font(BrandFonts.sans(14.5, weight: .semibold))
                        Text("Stops tracking here and revokes this Mac's key. Your history stays on lobsterone.ai.")
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    DisconnectButton(title: "Sign out") { onSignOut() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(BrandFonts.sans(13.5, weight: .medium))
                .foregroundStyle(PopoverPalette.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? BrandFonts.mono(12.5) : BrandFonts.sans(14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                GarrySprite(walking: router.tab == .about, scale: 1.6) // only while this tab shows
                    .padding(.top, 6)
                Rectangle().fill(PopoverPalette.lineStrong).frame(height: 1)
                    .frame(maxWidth: 240)
            }
            VStack(spacing: 6) {
                Text("LobsterOne")
                    .font(BrandFonts.sans(24, weight: .semibold))
                Text(versionText)
                    .font(BrandFonts.mono(12))
                    .foregroundStyle(PopoverPalette.secondary)
                    .textSelection(.enabled)
                Text("Updates download and install on their own while you're away from the keyboard.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 8) {
                PillButton(title: "Check for Updates", prominent: true) { onCheckForUpdates() }
                PillButton(title: "lobsterone.ai", prominent: false) {
                    NSWorkspace.shared.open(URL(string: "https://lobsterone.ai")!)
                }
            }

            VStack(spacing: 8) {
                Text("Something not working?")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                HStack(spacing: 8) {
                    PillButton(title: "Diagnostics", prominent: false) { router.tab = .diagnostics }
                    PillButton(title: "Logs", prominent: false) { router.tab = .logs }
                }
            }

            Text("Sounds: mission and Mars audio courtesy NASA and NASA/JPL-Caltech; Saturn and Jupiter recordings courtesy NASA and The University of Iowa; the Bloop courtesy NOAA PMEL. Gravitational-wave chirp from LIGO via gwosc.org (CC BY 4.0). Modem handshake by ~peron, Internet Archive (CC BY 4.0). Numbers station and teletype recorded by Oona R\u{E4}is\u{E4}nen (public domain). Freesound CC0 recordings by eZZin, Squidems and SpliceSound; dial tones and boxing bell from Wikimedia Commons (CC0). LobsterOne isn't affiliated with or endorsed by NASA, NOAA or LIGO.")
                .font(BrandFonts.sans(11.5))
                .foregroundStyle(PopoverPalette.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Garry says thanks for keeping him busy.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.tertiary)
                Spacer(minLength: 8)
                DisconnectButton(title: "Quit LobsterOne") { NSApp.terminate(nil) }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    /// Shown under the alerts toggle when macOS won't let the alerts through.
    private var notificationPermissionNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(notificationPermission == .denied
                 ? "Notifications are off for LobsterOne in System Settings, so these alerts can't appear."
                 : "LobsterOne hasn't been allowed to send notifications yet.")
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.criticalText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(notificationPermission == .denied ? "Open Settings" : "Allow") {
                if notificationPermission == .denied {
                    let id = Bundle.main.bundleIdentifier ?? "com.lobsterone.mac"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    Task {
                        await PaceNotifier.requestPermission()
                        notificationPermission = await PaceNotifier.permission()
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// A sentence-case label over a Sand card, the same pairing the popover uses.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .medium))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.leading, 2)
            content()
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(PopoverPalette.divider).frame(height: 1)
    }

    private func detectTools() {
        isDetectingTools = true
        isAddingTool = true
        Task.detached {
            let sources = ConfigService().unconfiguredInstalledSources()
            await MainActor.run {
                unconfiguredSources = sources
                isDetectingTools = false
                if sources.isEmpty {
                    isAddingTool = false
                    addToolError = "All detected tools are already configured."
                }
            }
        }
    }

    private func sourceRow(_ source: SourceStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(Self.monogram(source.displayName))
                .font(BrandFonts.mono(12.5, weight: .bold))
                .foregroundStyle(PopoverPalette.text)
                .frame(width: 36, height: 36)
                .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(dotColor(source.statusLevel))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(PopoverPalette.card, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(source.displayName)
                        .font(BrandFonts.sans(14.5, weight: .semibold))
                        .layoutPriority(1)
                    if let key = source.keyPrefix {
                        Text(key.replacingOccurrences(of: "...", with: "\u{2026}"))
                            .font(BrandFonts.mono(11.5))
                            .foregroundStyle(PopoverPalette.tertiary)
                            .help("The start of this tool's LobsterOne key")
                    }
                }
                .lineLimit(1)
                Text(source.statusLevel == .waiting
                     ? "Connected. Use \(source.displayName) once and its first session shows up here."
                     : source.lastSeenText)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(source.statusLevel == .disconnected ? PopoverPalette.criticalText : PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if source.todayTokens > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(SevenDayBurn.formatTokens(source.todayTokens))
                        .font(BrandFonts.sans(16, weight: .semibold))
                        .monospacedDigit()
                    Text("tokens today")
                        .font(BrandFonts.sans(11))
                        .foregroundStyle(PopoverPalette.tertiary)
                }
                .padding(.trailing, 4)
            }

            DisconnectButton {
                onDisconnect(source.id)
                Task {
                    sourceStatuses = await onRefreshSources()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Two letters for a tool's tile: initials of a two-word name, else the first two letters.
    static func monogram(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(name.prefix(2)).uppercased()
    }

    private var addToolSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a tool")
                .font(BrandFonts.sans(17, weight: .semibold))

            if isDetectingTools {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for installed tools\u{2026}")
                        .font(BrandFonts.sans(13.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("Pick an installed tool to connect.")
                    .font(BrandFonts.sans(13.5))
                    .foregroundStyle(PopoverPalette.secondary)

                VStack(spacing: 0) {
                    ForEach(unconfiguredSources, id: \.type) { source in
                        SettingsRowButton {
                            isAddingTool = false
                            Task {
                                do {
                                    try await onAddTool(source.type)
                                    sourceStatuses = await onRefreshSources()
                                } catch {
                                    addToolError = "Failed to add \(source.displayName): \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            HStack {
                                Text(source.displayName)
                                    .font(BrandFonts.sans(14.5, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(PopoverPalette.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        if source.type != unconfiguredSources.last?.type { rowDivider }
                    }
                }
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isAddingTool = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
    }

    private func dotColor(_ level: SourceStatus.StatusLevel) -> Color {
        switch level {
        case .active: PopoverPalette.dotActive
        case .waiting: PopoverPalette.dotWaiting
        case .disconnected: PopoverPalette.dotOff
        }
    }
}

/// The Dictation card on Preferences. Its own view so the controller's live level and
/// transcript, which change many times a second while dictating, only redraw these rows.
private struct DictationSettingsRows: View {
    @ObservedObject var controller: DictationController
    /// False while another tab is in front. Pages stay alive behind the tab bar, so this is
    /// how a shortcut recording left running is stopped.
    var isShown = true
    @State private var microphones: [DictationMicrophones.Microphone] = []
    /// The chosen microphone's UID; empty follows the system default.
    @State private var selectedMicrophone = ""
    /// Every language the model knows, loaded when the card first shows.
    @State private var languages: [DictationLanguage.Option] = []
    /// The chosen language's identifier; empty follows the system language.
    @State private var selectedLanguage = DictationLanguage.selectedIdentifier ?? ""
    @State private var isRecordingShortcut = false
    @State private var recorder = ShortcutRecorder()
    @State private var recordMonitor: Any?
    /// Why the last shortcut pressed can't be used.
    @State private var shortcutProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate into any app")
                        .font(BrandFonts.sans(14.5, weight: .semibold))
                    Text(subtitle)
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if controller.availability == .needsMacOS26 {
                    // A switch that can't be switched says nothing; the way forward is the update.
                    PillButton(title: "Update macOS", prominent: false) { DictationPermissions.openSoftwareUpdate() }
                } else {
                    Toggle("Dictate into any app", isOn: Binding(
                        get: { controller.isOn && isAvailable },
                        set: { controller.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(PopoverPalette.brand)
                    .disabled(!isAvailable)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if controller.isOn && isAvailable {
                rowDivider
                shortcutRow
                rowDivider
                streamingRow
                rowDivider
                statusRow("Microphone", dot: microphoneDot, text: microphoneText) {
                    switch controller.microphone {
                    case .allowed: microphonePicker
                    case .notAsked: PillButton(title: "Allow", prominent: false) { controller.requestMicrophone() }
                    case .denied: PillButton(title: "Open System Settings", prominent: false) { DictationPermissions.openMicrophoneSettings() }
                    }
                }
                rowDivider
                statusRow("Accessibility", dot: controller.accessibility ? PopoverPalette.dotActive : PopoverPalette.dotWaiting,
                          text: controller.accessibility ? "Allowed." : "Needed to hear the key in other apps and to paste.") {
                    if !controller.accessibility {
                        PillButton(title: "Open System Settings", prominent: false) { DictationPermissions.openAccessibilitySettings() }
                    }
                }
                rowDivider
                statusRow("Language", dot: modelDot, text: languageText) { languagePicker }
            }
        }
        // Re-check when Settings opens and when coming back from System Settings.
        .onAppear {
            controller.refreshPermissions()
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
        // A recording only makes sense while the person is looking at it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecordingShortcut()
        }
        .onChange(of: isShown) { _, shown in
            if !shown { stopRecordingShortcut() }
        }
        .onChange(of: controller.isOn) { _, on in
            if !on { stopRecordingShortcut() }
        }
        .onDisappear { stopRecordingShortcut() }
    }

    // MARK: Shortcut

    private var shortcutRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shortcut")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text(shortcutLine)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(shortcutProblem == nil ? PopoverPalette.secondary : PopoverPalette.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
                if !isRecordingShortcut, controller.shortcut == .modifier(.fn) {
                    Text("macOS may also act on the Globe key. In System Settings \u{2192} Keyboard, set \u{201C}Press \u{1F310} key to\u{201D} to \u{201C}Do Nothing\u{201D}.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !isRecordingShortcut, controller.shortcut != .defaultValue {
                Button("Reset") { choose(.defaultValue) }
                    .buttonStyle(.plain)
                    .font(BrandFonts.sans(12.5, weight: .semibold))
                    .foregroundStyle(PopoverPalette.text)
                    .fixedSize()
            }
            PillButton(title: isRecordingShortcut ? "Cancel" : "Change", prominent: false) {
                if isRecordingShortcut { stopRecordingShortcut() } else { startRecordingShortcut() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var streamingRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Type as you speak")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text("Words appear while you hold the shortcut, and are corrected as the sentence settles. Off: the text is pasted when you release.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("Type as you speak", isOn: Binding(
                get: { controller.typesWhileSpeaking },
                set: { controller.setStreaming($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(PopoverPalette.brand)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var shortcutLine: String {
        if let shortcutProblem { return shortcutProblem }
        if isRecordingShortcut { return "Press a key or a combination. Esc to cancel." }
        return controller.shortcut.displayName
    }

    /// Listens to the Settings window, which is key while the person presses the new shortcut.
    /// The dictation key is off meanwhile, so the old shortcut neither dictates nor, as a
    /// hotkey, swallows the press before it gets here.
    private func startRecordingShortcut() {
        guard !isRecordingShortcut else { return }
        controller.suspendKey()
        recorder = ShortcutRecorder()
        shortcutProblem = nil
        isRecordingShortcut = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            // Swallowed so a press doesn't beep, type, or fire a menu item such as ⌘W.
            MainActor.assumeIsolated { record(event) } ? nil : event
        }
    }

    private func stopRecordingShortcut() {
        guard isRecordingShortcut else { return }
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        isRecordingShortcut = false
        shortcutProblem = nil
        controller.resumeKey()
    }

    /// True when the event was used and should go no further.
    private func record(_ event: NSEvent) -> Bool {
        let raw = UInt64(event.modifierFlags.rawValue)
        let input: ShortcutRecorder.Input
        switch event.type {
        case .flagsChanged:
            // Caps Lock passes through and keeps working.
            guard let key = ModifierKey(keyCode: event.keyCode) else { return false }
            input = key.isDown(rawFlags: raw) ? .modifierDown(keyCode: key.keyCode) : .modifierUp(keyCode: key.keyCode)
        case .keyDown:
            if event.isARepeat { return true }
            input = .keyDown(keyCode: event.keyCode, modifiers: DictationShortcut.Modifiers(rawFlags: raw))
        default:
            return false
        }
        switch recorder.handle(input) {
        case nil:
            break
        case .cancelled:
            stopRecordingShortcut()
        case .rejected(let reason):
            shortcutProblem = reason
        case .recorded(let shortcut):
            choose(shortcut)
        }
        return true
    }

    /// A refusal keeps the recording going, so the person can try another.
    private func choose(_ shortcut: DictationShortcut) {
        if let problem = controller.setShortcut(shortcut) {
            shortcutProblem = problem
            return
        }
        stopRecordingShortcut()
    }

    /// System default first, then every microphone connected now. A chosen one that is
    /// unplugged stays listed, so the choice isn't lost by opening Settings without it.
    private var microphonePicker: some View {
        Picker("Microphone", selection: Binding(
            get: { selectedMicrophone },
            set: { uid in
                selectedMicrophone = uid
                DictationMicrophones.selectedUID = uid.isEmpty ? nil : uid
                DebugLog.shared.log("Dictation: microphone set to \(uid.isEmpty ? "the system default" : "a chosen device")")
            }
        )) {
            Text(DictationMicrophones.systemDefaultName.map { "System default (\($0))" } ?? "System default").tag("")
            Divider()
            ForEach(microphones) { Text($0.name).tag($0.uid) }
            if !selectedMicrophone.isEmpty, !microphones.contains(where: { $0.uid == selectedMicrophone }) {
                Text("Not connected").tag(selectedMicrophone)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    /// The model hears one language at a time, so this is how a French speaker on an English
    /// Mac gets French. A chosen language the model no longer lists stays shown, by name.
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
        .task { if languages.isEmpty { languages = await DictationLanguage.supported() } }
    }

    private func refreshMicrophones() {
        microphones = DictationMicrophones.available()
        selectedMicrophone = DictationMicrophones.selectedUID ?? ""
    }

    /// Unknown while the first check runs, which is too quick to be worth a state of its own.
    private var isAvailable: Bool { controller.availability == .available }

    private var subtitle: String {
        if let explanation = DictationController.unavailableExplanation(
            controller.availability, osVersion: ProcessInfo.processInfo.operatingSystemVersion) {
            return explanation
        }
        return "\(controller.shortcut.holdInstruction) The text is typed where your cursor is. Speech is transcribed on this Mac."
    }

    private var microphoneDot: Color {
        switch controller.microphone {
        case .allowed: return PopoverPalette.dotActive
        case .denied: return PopoverPalette.critical
        case .notAsked: return PopoverPalette.dotWaiting
        }
    }

    private var microphoneText: String {
        switch controller.microphone {
        case .allowed: return "Allowed."
        case .denied: return "Off for LobsterOne, so it can't hear you."
        case .notAsked: return "Not asked yet."
        }
    }

    private var modelDot: Color {
        switch controller.modelState {
        case .ready: return PopoverPalette.dotActive
        case .failed: return PopoverPalette.critical
        case .unknown, .notInstalled, .downloading: return PopoverPalette.dotWaiting
        }
    }

    private var languageText: String {
        let model: String
        switch controller.modelState {
        case .unknown: model = "Checking\u{2026}"
        case .notInstalled: model = "Speech model not downloaded yet"
        case .downloading(let fraction): model = "Downloading \(Int((fraction * 100).rounded()))%"
        case .ready: model = "Ready"
        case .failed(let reason): model = reason
        }
        guard let name = controller.languageName else { return model }
        return "\(name) · \(model)"
    }

    /// Same layout as the Notifications tab's permission row.
    private func statusRow<Action: View>(_ title: String, dot: Color, text: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                    Text(text)
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Matches SettingsView's row divider; that one is private to the view.
    private var rowDivider: some View {
        Rectangle().fill(PopoverPalette.divider).frame(height: 1)
    }
}

/// A full-width row that works as a button, with the popover's soft hover fill.
private struct SettingsRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .background(hovering ? PopoverPalette.cardHover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A pill: Lobster with white text for the main action, white with a Line strong border for the rest.
private struct PillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .semibold))
                .foregroundStyle(prominent ? PopoverPalette.onBrand : PopoverPalette.text)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(prominent ? (hovering ? PopoverPalette.primaryHover : PopoverPalette.brand)
                                      : (hovering ? PopoverPalette.hover : PopoverPalette.background), in: Capsule())
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : PopoverPalette.lineStrong))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `PillButton` for panes kept in their own files; other files have private pills of that name.
struct SettingsPill: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View { PillButton(title: title, prominent: prominent, action: action) }
}

/// Quiet until hovered, then red: for actions that stop something (disconnect, sign out, quit).
struct DisconnectButton: View {
    var title = "Disconnect"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(hovering ? PopoverPalette.criticalText : PopoverPalette.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(hovering ? PopoverPalette.criticalBackground : PopoverPalette.background, in: Capsule())
                .overlay(Capsule().strokeBorder(hovering ? Color.clear : PopoverPalette.lineStrong))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The row of tabs across the top: the settings on the left, help on the right, Lobster on
/// Blush for the chosen one.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.shown.filter { !$0.isHelp }) { tab in button(tab) }
            Spacer(minLength: 10)
            Rectangle().fill(PopoverPalette.divider).frame(width: 1, height: 30)
            Spacer(minLength: 10)
            ForEach(SettingsTab.shown.filter(\.isHelp)) { tab in button(tab) }
        }
        .frame(maxWidth: .infinity)
    }

    /// ⌘1 to ⌘9 for the first nine tabs. A tenth gets none: "10" isn't one key.
    @ViewBuilder
    private func button(_ tab: SettingsTab) -> some View {
        // About stays lit while one of its pages, Diagnostics or Logs, is open.
        let selected = tab == selection || (tab == .about && selection.isUnderAbout)
        let button = SettingsTabButton(tab: tab, selected: selected) { selection = tab }
        if let number = tab.shortcutNumber {
            button.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        } else {
            button
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                AccentGlyph(shape: tab.glyph, size: 22,
                            outline: selected || hovering ? PopoverPalette.text : PopoverPalette.secondary)
                Text(tab.title)
                    .font(BrandFonts.sans(11.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? PopoverPalette.brandText : (hovering ? PopoverPalette.text : PopoverPalette.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 60)
            .frame(height: 56)
            .background(selected ? PopoverPalette.blush : (hovering ? PopoverPalette.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.shortcutNumber.map { "\(tab.title) (⌘\($0))" } ?? tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small rounded label: Blush and Lobster by default, green for good news, or quiet.
struct Chip: View {
    enum Tone { case brand, success, quiet }

    let text: String
    var tone: Tone = .brand

    init(text: String, tone: Tone = .brand) {
        self.text = text
        self.tone = tone
    }

    init(text: String, quiet: Bool) {
        self.init(text: text, tone: quiet ? .quiet : .brand)
    }

    var body: some View {
        Text(text)
            .font(BrandFonts.sans(11.5, weight: .semibold))
            .foregroundStyle(tone == .brand ? PopoverPalette.brandText : tone == .success ? PopoverPalette.successText : PopoverPalette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(tone == .brand ? PopoverPalette.blush : tone == .success ? PopoverPalette.successBackground : PopoverPalette.background,
                        in: Capsule())
    }
}

/// Garry, in pixels. Walks in place unless he's asked to rest or the Mac asks for less motion.
struct GarrySprite: View {
    var walking: Bool
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let idle = image("garry-idle")
    private static let walk = (1...4).compactMap { image("garry-walk-\($0)") }

    var body: some View {
        Group {
            if walking && !reduceMotion && !Self.walk.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.14)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.14) % Self.walk.count
                    sprite(Self.walk[frame])
                }
            } else if let idle = Self.idle {
                sprite(idle)
            }
        }
        .frame(width: 75 * scale, height: 71 * scale)
        .accessibilityLabel("Garry the lobster")
    }

    private func sprite(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private static func image(_ name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Garry").flatMap(NSImage.init(contentsOf:))
        #else
        // The Xcode project flattens resources into Contents/Resources.
        return Bundle.main.image(forResource: name)
        #endif
    }
}

/// A stand-in for the macOS banner a usage cap alert produces, in the app's colours.
struct AlertPreview: View {
    /// The banner's soft shadow; off where the page around it has none.
    var lifted = true

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("LobsterOne")
                        .font(BrandFonts.sans(12, weight: .semibold))
                        .foregroundStyle(PopoverPalette.secondary)
                    Spacer()
                    Text("now")
                        .font(BrandFonts.sans(11.5))
                        .foregroundStyle(PopoverPalette.tertiary)
                }
                Text("Session cap in about 1h 30m")
                    .font(BrandFonts.sans(13.5, weight: .semibold))
                Text("At this pace you'll be locked out 27m before the session resets.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PopoverPalette.lineStrong))
        .shadow(color: .black.opacity(lifted ? 0.08 : 0), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example alert: Session cap in about 1 hour 30 minutes")
    }
}

// MARK: - Sounds

/// Sounds for coding-agent moments, played by hooks LobsterOne writes into Claude Code's
/// settings (and Codex's and Vibe's hook files, when chosen). Saved and applied on every change.
private struct SoundsPane: View {
    @State private var settings = SoundCueSettings.load()
    @State private var ownSounds: Set<SoundCue> = []
    @State private var customSounds: [SoundChoice] = []
    @State private var macSounds: [URL] = []
    @State private var error: String?
    /// Why a tool's hooks couldn't be written, per tool, so one broken file doesn't hide the rest.
    @State private var toolErrors: [SoundTool: String] = [:]
    /// Tools found on this Mac besides Claude Code.
    @State private var detected: Set<SoundTool> = []
    /// The "Review…" popover for moments the person's own hooks already sound at.
    @State private var reviewingOwnSounds = false
    private let installer = SoundCueInstaller()
    private let systemSounds = SoundCueInstaller.systemSoundNames()

    /// Claude Code always; Codex and Vibe when they're on this Mac, or already switched on.
    private var visibleTools: [SoundTool] {
        SoundTool.allCases.filter { $0 == .claude || detected.contains($0) || settings.tools.contains($0) }
    }

    /// Moments that are on where the person's own Claude Code hooks already play a sound.
    private var doubledMoments: [SoundCue] {
        guard settings.plays(in: .claude) else { return [] }
        return SoundCue.allCases.filter { ownSounds.contains($0) && settings.entry($0).on }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Play sounds in")
                                .font(BrandFonts.sans(14.5, weight: .semibold))
                            HStack(spacing: 6) {
                                ForEach(visibleTools) { tool in toolChip(tool) }
                            }
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(PopoverPalette.tertiary)
                            Slider(value: $settings.volume, in: 0.1...1) { editing in
                                if !editing { save() }
                            }
                            .tint(PopoverPalette.brand)
                            .controlSize(.small)
                            .frame(width: 130)
                            .accessibilityLabel("Volume")
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(PopoverPalette.tertiary)
                        }
                        .disabled(!settings.enabled)
                        .opacity(settings.enabled ? 1 : 0.5)
                        .help("Volume")
                    }
                    ForEach(visibleTools) { tool in
                        if settings.plays(in: tool), let note = note(for: tool) {
                            smallLine(note, color: PopoverPalette.secondary)
                        }
                        if let message = toolErrors[tool] {
                            smallLine(message, color: PopoverPalette.criticalText)
                        }
                    }
                    smallLine("LobsterOne adds small hooks to each tool's settings, so sounds play even when this app is closed. Your own hooks stay as they are.",
                              color: PopoverPalette.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            if !doubledMoments.isEmpty {
                ownSoundsNotice(doubledMoments)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Pack")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(SoundPack.all) { pack in
                            SoundPackCover(pack: pack, selected: settings.pack?.id == pack.id) { use(pack) }
                        }
                    }
                    // Room for the selected cover's outline.
                    .padding(4)
                }
                .padding(.horizontal, -4)
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Moments")
                card {
                    VStack(spacing: 0) {
                        ForEach(Array(SoundCue.allCases.enumerated()), id: \.element) { index, cue in
                            if index > 0 { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
                            row(cue)
                        }
                    }
                }
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)

            card {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(PopoverPalette.tertiary)
                            .accessibilityHidden(true)
                        Text("Quiet times")
                            .font(BrandFonts.sans(13.5, weight: .semibold))
                        if settings.quietTimes.isEmpty {
                            Text("None")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                        }
                        Spacer(minLength: 8)
                        PillButton(title: "Add", prominent: false) {
                            settings.quietTimes.append(QuietTime())
                            save()
                        }
                        .help("Add a quiet time: no sounds during those hours, every day")
                        .accessibilityLabel("Add a quiet time")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    ForEach($settings.quietTimes) { $quiet in
                        Rectangle().fill(PopoverPalette.divider).frame(height: 1)
                        quietRow($quiet)
                    }
                }
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)

            if let error {
                Text(error)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("New sessions pick up changes; a session that's already open keeps the sounds it started with.")
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .onAppear {
            detected = Set([CodexSoundCueInstaller.isDetected() ? SoundTool.codex : nil,
                            VibeSoundCueInstaller.isDetected() ? SoundTool.vibe : nil].compactMap { $0 })
            ownSounds = installer.cuesWithOwnSounds()
            customSounds = installer.customSounds()
            let imported = Set(customSounds.map(\.label))
            macSounds = installer.soundsOnThisMac().filter { !imported.contains($0.deletingPathExtension().lastPathComponent) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(BrandFonts.sans(13, weight: .medium))
            .foregroundStyle(PopoverPalette.secondary)
            .padding(.leading, 2)
    }

    private func smallLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(BrandFonts.sans(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What's different about playing sounds in a tool, shown while its chip is on.
    private func note(for tool: SoundTool) -> String? {
        switch tool {
        case .claude: nil
        case .codex: "Codex asks you to trust new hooks once. Choose Trust all next time you start it."
        case .vibe: "Needs Vibe 3.1.1 or newer. Waiting plays when Vibe asks you a question; Plan approved isn't available. Vibe's own terminal bell may ring too."
        }
    }

    /// A tool chip: Ink with a Seagrass dot when sounds play there, white with a hairline when not.
    /// Sounds are on while at least one tool is chosen.
    private func toolChip(_ tool: SoundTool) -> some View {
        let selected = settings.plays(in: tool)
        return Button {
            if selected {
                settings.tools.remove(tool)
            } else if settings.enabled {
                settings.tools.insert(tool)
            } else {
                // Coming back from off: start from just this tool.
                settings.tools = [tool]
            }
            settings.enabled = !settings.tools.isEmpty
            save()
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Circle().fill(PopoverPalette.seagrass).frame(width: 7, height: 7)
                }
                Text(tool.title)
                    .font(BrandFonts.sans(12.5, weight: .semibold))
                    .foregroundStyle(selected ? PopoverPalette.background : PopoverPalette.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? PopoverPalette.text : PopoverPalette.background, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : PopoverPalette.lineStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "Stop playing sounds in \(tool.title)" : "Play sounds in \(tool.title)")
        .accessibilityLabel("Play sounds in \(tool.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One notice for every moment where the person's own hooks sound too, with a way to
    /// switch LobsterOne's off there.
    private func ownSoundsNotice(_ cues: [SoundCue]) -> some View {
        HStack(spacing: 10) {
            Text("Your own Claude Code hooks already play sounds at \(cues.count) of these moments, so you'll hear both.")
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.warningText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Review\u{2026}") { reviewingOwnSounds = true }
                .buttonStyle(.plain)
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(PopoverPalette.text)
                .fixedSize()
                .popover(isPresented: $reviewingOwnSounds, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your own hooks also play at")
                            .font(BrandFonts.sans(13, weight: .semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(cues) { cue in
                                Text(cue.shortTitle).font(BrandFonts.sans(13))
                            }
                        }
                        PillButton(title: "Turn these off in LobsterOne", prominent: true) {
                            for cue in cues {
                                var entry = settings.entry(cue)
                                entry.on = false
                                settings.cues[cue] = entry
                            }
                            reviewingOwnSounds = false
                            save()
                        }
                        Text("Or remove your own hooks from ~/.claude/settings.json.")
                            .font(BrandFonts.sans(12))
                            .foregroundStyle(PopoverPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: 280, alignment: .leading)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PopoverPalette.warningBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ cue: SoundCue) -> some View {
        let entry = settings.entry(cue)
        let on = Binding(get: { settings.entry(cue).on }, set: { value in
            var entry = settings.entry(cue)
            entry.on = value
            settings.cues[cue] = entry
            save()
        })
        let label = label(for: entry)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.shortTitle)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                if cue == .waiting {
                    Text("After a minute idle")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
            }
            .help(cue.detail)
            .opacity(entry.on ? 1 : 0.5)
            Spacer(minLength: 8)
            picker(cue, current: entry, label: label)
                .disabled(!entry.on)
                .opacity(entry.on ? 1 : 0.5)
            Button {
                SoundCueInstaller.preview(entry, volume: settings.volume(for: cue))
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PopoverPalette.brandText)
                    .frame(width: 30, height: 30)
                    .background(PopoverPalette.blush, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(entry.on ? 1 : 0.5)
            .help("Play \(label)")
            .accessibilityLabel("Play \(label)")
            Toggle(cue.shortTitle, isOn: on)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(PopoverPalette.brand)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The levels the sound menu offers, as a share of the main volume.
    private static let levels: [Double] = [1, 0.75, 0.5, 0.25]

    /// A saved level shown as the nearest of the menu's four.
    private static func nearestLevel(_ level: Double) -> Double {
        levels.min { abs($0 - level) < abs($1 - level) } ?? 1
    }

    private func setLevel(_ level: Double, for cue: SoundCue) {
        var entry = settings.entry(cue)
        entry.level = level
        settings.cues[cue] = entry
        save()
        SoundCueInstaller.preview(settings.entry(cue), volume: settings.volume(for: cue))
    }

    /// A cue set to random over numbered versions reads "Hello (random)".
    /// The sound's name as the row shows it: a numbered set by its plain name ("Battle control",
    /// not "Battle control (random)"), and Garry's sounds without the "Garry:" prefix. The menu
    /// still spells both out.
    private func label(for entry: SoundCueSettings.Entry) -> String {
        let name = entry.random && variants(entry.sound).count > 1 ? entry.sound.familyLabel : entry.sound.label
        return name.hasPrefix("Garry: ") ? String(name.dropFirst("Garry: ".count)) : name
    }

    private func variants(_ choice: SoundChoice) -> [SoundChoice] {
        SoundChoice.variants(of: choice, custom: customSounds)
    }

    /// Sounds on this Mac that come in numbered versions, grouped: hello-1, hello-2, hello-3.
    private var macFamilies: [String: [URL]] {
        Dictionary(grouping: macSounds.filter { SoundChoice.familyStem($0.deletingPathExtension().lastPathComponent) != nil }) {
            SoundChoice.familyStem($0.deletingPathExtension().lastPathComponent) ?? ""
        }.filter { $0.value.count > 1 }
    }

    private func picker(_ cue: SoundCue, current: SoundCueSettings.Entry, label: String) -> some View {
        let families = macFamilies
        let level = Self.nearestLevel(current.level)
        return Menu {
            Section("Level") {
                ForEach(Self.levels, id: \.self) { choice in
                    let title = "\(Int(choice * 100))%"
                    Button { setLevel(choice, for: cue) } label: {
                        if choice == level { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            ForEach(SoundChoice.bundledSets, id: \.title) { set in
                Section(set.title) {
                    ForEach(set.sounds, id: \.id) { sound in
                        items(cue, .garry(sound.id), current: current)
                    }
                }
            }
            Section("macOS") {
                ForEach(systemSounds, id: \.self) { name in items(cue, .system(name), current: current) }
            }
            if !macSounds.isEmpty {
                Section("On this Mac") {
                    ForEach(macSounds, id: \.self) { url in
                        let name = url.deletingPathExtension().lastPathComponent
                        if let stem = SoundChoice.familyStem(name), let family = families[stem], family.first == url {
                            Button("\(stem) (random)") { use(family, for: cue) }
                        }
                        Button(name) { use([url], for: cue) }
                    }
                }
            }
            Section("Your sounds") {
                ForEach(customSounds, id: \.self) { choice in items(cue, choice, current: current) }
                Button("Choose a file\u{2026}") { chooseFile(for: cue) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(BrandFonts.sans(13, weight: .semibold))
                    .foregroundStyle(PopoverPalette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PopoverPalette.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(level < 1 ? "Sound and level (\(Int(level * 100))%)" : "Sound and level")
        .accessibilityLabel("Sound for \(cue.shortTitle): \(label)")
    }

    /// One sound's menu item, with a "random" item ahead of the first of any numbered set.
    @ViewBuilder
    private func items(_ cue: SoundCue, _ choice: SoundChoice, current: SoundCueSettings.Entry) -> some View {
        let family = variants(choice)
        let currentIsRandom = current.random && variants(current.sound).count > 1
        if family.count > 1, family.first == choice {
            item(cue, choice, random: true, title: "\(choice.familyLabel) (random)",
                 checked: currentIsRandom && family.contains(current.sound))
        }
        item(cue, choice, random: false, title: choice.label, checked: !currentIsRandom && choice == current.sound)
    }

    private func item(_ cue: SoundCue, _ choice: SoundChoice, random: Bool, title: String, checked: Bool) -> some View {
        Button {
            var entry = settings.entry(cue)
            entry.sound = choice
            entry.random = random
            settings.cues[cue] = entry
            SoundCueInstaller.preview(entry, volume: settings.volume(for: cue))
            save()
        } label: {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func chooseFile(for cue: SoundCue) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a short sound for \u{201C}\(cue.title)\u{201D}"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use([url], for: cue)
    }

    /// Copies sounds in and picks them for this moment: one sound, or a numbered set to
    /// play at random.
    private func use(_ urls: [URL], for cue: SoundCue) {
        do {
            let choices = try urls.map { try installer.importCustomSound(from: $0) }
            guard let first = choices.first else { return }
            customSounds = installer.customSounds()
            macSounds.removeAll { urls.contains($0) }
            var entry = settings.entry(cue)
            entry.sound = first
            entry.random = choices.count > 1
            settings.cues[cue] = entry
            SoundCueInstaller.preview(entry, volume: settings.volume(for: cue))
            save()
        } catch {
            self.error = "Couldn't add that file: \(error.localizedDescription)"
        }
    }

    private func quietRow(_ quiet: Binding<QuietTime>) -> some View {
        HStack(spacing: 10) {
            Text("From").font(BrandFonts.sans(13.5))
            DatePicker("Quiet from", selection: time(quiet.start), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("to").font(BrandFonts.sans(13.5))
            DatePicker("Quiet until", selection: time(quiet.end), displayedComponents: .hourAndMinute)
                .labelsHidden()
            if quiet.wrappedValue.end <= quiet.wrappedValue.start {
                Text("the next day")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                settings.quietTimes.removeAll { $0.id == quiet.wrappedValue.id }
                save()
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(PopoverPalette.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove this quiet time")
            .accessibilityLabel("Remove this quiet time")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    /// A time-of-day picker's Date for minutes since midnight, saving on change.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Binding(get: { midnight.addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            save()
        })
    }

    /// Applies a pack and plays its session-start sound as a taste.
    private func use(_ pack: SoundPack) {
        settings.apply(pack)
        SoundCueInstaller.preview(settings.entry(.sessionStart), volume: settings.volume(for: .sessionStart))
        save()
    }

    private func save() {
        toolErrors = settings.saveAndInstall()
        error = nil
        ownSounds = installer.cuesWithOwnSounds()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// A pack's cover with its name under it. The chosen one gets a Lobster outline.
struct SoundPackCover: View {
    let pack: SoundPack
    let selected: Bool
    /// Plays a sample of the pack. When set, a play button shows over the picture on hover.
    var play: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false

    /// `hovering` sets how the cover starts, for previews and renders; the pointer takes over from there.
    init(pack: SoundPack, selected: Bool, hovering: Bool = false, play: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.pack = pack
        self.selected = selected
        self.play = play
        self.action = action
        self._hovering = State(initialValue: hovering)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    PopoverPalette.card
                    if let art = Self.art(pack.id) {
                        Image(nsImage: art).resizable().interpolation(.high).scaledToFill()
                            .scaleEffect(hovering ? 1.05 : 1)
                            .animation(.easeOut(duration: 0.2), value: hovering)
                    }
                }
                .frame(width: 76, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? PopoverPalette.brand : Color.clear, lineWidth: 2)
                    .padding(-4))
                .accessibilityHidden(true)
                Text(pack.name)
                    .font(BrandFonts.sans(11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? PopoverPalette.brandText : (hovering ? PopoverPalette.text : PopoverPalette.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The play button sits over the picture, outside the tile's own button, so a click on it
        // plays the sample without also choosing the pack.
        .overlay(alignment: .top) {
            if hovering, let play {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PopoverPalette.brandText)
                        .offset(x: 1)
                        .frame(width: 28, height: 28)
                        .background(PopoverPalette.background, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 76, height: 52)
                .help("Play a sample")
                .accessibilityLabel("Play a sample of the \(pack.name) pack")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(pack.detail)
        .accessibilityLabel("\(pack.name) pack. \(pack.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Hover is out of reach for VoiceOver and the keyboard, so the sample is an action too.
        .accessibilityAction(named: "Play a sample") { play?() }
    }

    private static var cache: [String: NSImage] = [:]

    /// The pack's cover art, from Resources/Packs.
    private static func art(_ id: String) -> NSImage? {
        if let image = cache[id] { return image }
        #if SWIFT_PACKAGE
        let image = Bundle.module.url(forResource: "pack-\(id)", withExtension: "jpg", subdirectory: "Packs").flatMap(NSImage.init(contentsOf:))
        #else
        // The Xcode project flattens resources into Contents/Resources.
        let image = Bundle.main.image(forResource: "pack-\(id)")
        #endif
        cache[id] = image
        return image
    }
}
