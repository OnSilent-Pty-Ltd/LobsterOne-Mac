import Combine
import Sparkle
import SwiftUI
import AppKit
import ServiceManagement

@main
struct LobsterOneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Adapts a set of closures to `AuthRecoveryEnvironment`, so `AppDelegate` can
/// supply live side effects (which touch @MainActor services) without making the
/// coordinator depend on AppKit. Each closure hops to the main actor internally.
struct ClosureAuthRecoveryEnvironment: AuthRecoveryEnvironment, @unchecked Sendable {
    let waitGrace: @Sendable () async -> Void
    let validate: @Sendable (String) async -> Bool
    let refresh: @Sendable () async -> Bool
    let reauth: @Sendable () async -> Bool
    let remint: @Sendable (String) async -> Bool
    let clock: @Sendable () -> Date
    let logger: @Sendable (String) -> Void

    init(waitForHealGrace: @escaping @Sendable () async -> Void,
         validateKey: @escaping @Sendable (String) async -> Bool,
         refreshSession: @escaping @Sendable () async -> Bool,
         reauthenticate: @escaping @Sendable () async -> Bool,
         remintKey: @escaping @Sendable (String) async -> Bool,
         now: @escaping @Sendable () -> Date,
         log: @escaping @Sendable (String) -> Void) {
        self.waitGrace = waitForHealGrace
        self.validate = validateKey
        self.refresh = refreshSession
        self.reauth = reauthenticate
        self.remint = remintKey
        self.clock = now
        self.logger = log
    }

    func waitForHealGrace() async { await waitGrace() }
    func validateKey(_ apiKey: String) async -> Bool { await validate(apiKey) }
    func refreshSession() async -> Bool { await refresh() }
    func reauthenticateInteractively() async -> Bool { await reauth() }
    func remintKey(sourceType: String) async -> Bool { await remint(sourceType) }
    func now() -> Date { clock() }
    func log(_ message: String) { logger(message) }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBar = StatusBarController()
    private let activityMonitor = ActivityMonitor()
    private let clientPolicyService = ClientPolicyService()
    private let codexScanner: CodexSessionScanner
    private let mistralVibeScanner: MistralVibeSessionScanner
    private let claudeScanner: ClaudeSessionScanner
    private let pollingService: PollingService
    private let configService = ConfigService()
    private let keychainService = KeychainService()
    private let authService = AuthService()
    private let anthropicQuotaService = AnthropicQuotaService()
    private let screensaverSnapshot = ScreensaverSnapshotWriter()
    private let paceNotifier = PaceNotifier()
    private lazy var townNotifier = TownInviteNotifier(pace: paceNotifier)
    private let pushRegistration = PushRegistration()
    private let updateGate = UpdateInstallGate()
    private let liveActivity = LiveActivityWatcher()
    private let dictation = DictationController()
    private lazy var dictationHUD = DictationHUD(controller: dictation)
    private let awsCosts = AWSCostService()
    private lazy var screensaverLeaderboard = ScreensaverLeaderboard(keychain: keychainService, auth: authService)
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let settingsRouter = SettingsRouter()
    private var settingsTitleCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var statusFetchTask: Task<Void, Never>?
    private var configWatcher: ConfigWatcher?
    private var appNapActivity: NSObjectProtocol?
    private var updateUIPromotedApp = false

    override init() {
        self.pollingService = PollingService(
            activityMonitor: activityMonitor,
            clientPolicy: clientPolicyService
        )
        self.codexScanner = CodexSessionScanner(
            activityMonitor: activityMonitor,
            clientPolicy: clientPolicyService
        )
        self.mistralVibeScanner = MistralVibeSessionScanner(
            activityMonitor: activityMonitor,
            clientPolicy: clientPolicyService
        )
        self.claudeScanner = ClaudeSessionScanner(
            activityMonitor: activityMonitor,
            clientPolicy: clientPolicyService
        )
        super.init()
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private lazy var authRecovery = AuthRecoveryCoordinator(env: makeRecoveryEnvironment())

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        paceNotifier.onOpen = { [weak self] in self?.statusBar.showPopover() }
        townNotifier.install()
        _ = dictationHUD
        dictation.start()

        // Prevent App Nap so polling timers keep firing when the app is in the background
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Monitoring AI coding tool usage"
        )

        try? SMAppService.mainApp.register()

        // Updates are silent by policy: checked hourly, downloaded in the background and
        // installed by `UpdateInstallGate` once the person is away. Forced on at every launch,
        // so a box unticked in an old Sparkle dialog can't bring the prompts back.
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
        updateGate.isInterfaceOpen = { [weak self] in
            guard let self else { return false }
            return self.statusBar.isPopoverShown
                || NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        }

        // Set up status bar immediately so the app has a persistent UI element
        statusBar.costMonitor = awsCosts.monitor
        statusBar.awsConnected = awsCosts.isConnected
        statusBar.costInMenuBar = awsCosts.showsTotalInMenuBar
        statusBar.setup()

        // An installed screensaver from an older app build is brought up to date.
        ScreensaverInstaller.updateIfOutdated()
        // An added Claude Code band gets this build's files; one never added is left alone.
        do {
            if try ClaudeCodeMod.filesOnly().refreshFiles() { DebugLog.shared.log("Claude Code band updated to this build") }
        } catch {
            DebugLog.shared.log("Claude Code band update failed: \(error.localizedDescription)")
        }
        screensaverSnapshot.style = ScreensaverInstaller.chosenStyle

        // Migrate credentials and config from old Robocog locations
        migrateFromRobocog()

        statusBar.onSignOut = { [weak self] in self?.signOut() }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onCheckForUpdates = { [weak self] in
            self?.checkForUpdatesOnRequest()
        }
        statusBar.onSettings = { [weak self] in self?.showSettings() }
        statusBar.onRefreshNow = { [weak self] in self?.pollingService.refreshNow() }
        statusBar.onShowDiagnostics = { [weak self] in self?.showSettings(tab: .diagnostics) }
        statusBar.onShowAWSSettings = { [weak self] in self?.showSettings(tab: .aws) }
        statusBar.onAddClaudeCodeBand = { [weak self] in
            // Settings, Tools asks Claude Code again when it appears, so it shows how this went.
            Task { @MainActor in
                do {
                    try await ClaudeCodeMod.live().install()
                } catch {
                    DebugLog.shared.log("Claude Code band from the Team page: \(error.localizedDescription)")
                }
                self?.showSettings(tab: .tools)
            }
        }
        statusBar.onNotificationsViewed = { [weak self] in
            self?.pollingService.markAllNotificationsRead()
        }
        statusBar.onJoinTown = { [weak self] inviteId in
            self?.townNotifier.open(inviteId: inviteId)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        DebugLog.shared.log("LobsterOne v\(version) (\(build)) · macOS \(os)")
        DebugLog.shared.log("Sparkle auto-install: \(updaterController.updater.automaticallyDownloadsUpdates)")
        DebugLog.shared.log("Sparkle auto-check: \(updaterController.updater.automaticallyChecksForUpdates), interval: \(Int(updaterController.updater.updateCheckInterval))s")

        let signedInKey = keychainService.readAPIKeyOrConfig()
        SetupGuide.noteLaunch(signedIn: signedInKey != nil, defaults: .standard)
        if let apiKey = signedInKey {
            startMonitoring(apiKey: apiKey)
        } else {
            showSetupWizard()
        }

        pollingService.$quotaState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                var mergedState = state

                // Merge Anthropic real quota data when available
                let anthState = self.anthropicQuotaService.state
                if anthState.source == .oauthAPI {
                    mergedState.percentUsed = anthState.primaryPct
                    mergedState.isRealQuota = true
                    mergedState.anthropicState = anthState
                    if let planLabel = anthState.planLabel {
                        mergedState.planTier = planLabel
                    }
                }

                self.statusBar.quotaState = mergedState
                self.statusBar.updateDisplay()
                if anthState.source == .oauthAPI {
                    self.paceNotifier.evaluate(.session, percent: anthState.fiveHourPct, resetsAt: anthState.fiveHourResetsAt)
                    self.paceNotifier.evaluate(.week, percent: anthState.sevenDayPct, resetsAt: anthState.sevenDayResetsAt)
                }
                self.screensaverSnapshot.update(quota: mergedState, burn: self.statusBar.sevenDayBurn)
                // Skip if a fetch is already in progress (don't cancel — that kills HTTP requests)
                if self.statusFetchTask == nil {
                    self.statusFetchTask = Task { @MainActor in
                        // Claude Code's row/gauge prefer the real Anthropic 5h % at render
                        // time (see StatusBarController.displayPercent), so no override here.
                        self.statusBar.sourceStatuses = await self.fetchSourceStatuses()
                        self.screensaverSnapshot.sources = self.statusBar.sourceStatuses
                            .filter { $0.todayTokens > 0 }
                            .map { ScreensaverSnapshot.Source(name: $0.displayName, tokens: $0.todayTokens) }
                        await self.refreshScreensaverLeaderboard()
                        self.statusBar.updateDisplay()
                        self.statusBar.buildMenu()
                        self.statusFetchTask = nil
                    }
                } else {
                    self.statusBar.buildMenu()
                }
            }
            .store(in: &cancellables)

        pollingService.$sevenDayBurn
            .receive(on: RunLoop.main)
            .sink { [weak self] burn in
                guard let self else { return }
                self.statusBar.sevenDayBurn = burn
                self.statusBar.buildMenu()
                self.screensaverSnapshot.update(quota: self.statusBar.quotaState, burn: burn)
            }
            .store(in: &cancellables)

        pollingService.$unreadNotificationCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                guard let self else { return }
                self.statusBar.unreadNotificationCount = count
                self.statusBar.updateDisplay()
                self.statusBar.buildMenu()
            }
            .store(in: &cancellables)

        pollingService.$townInvites
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] invites in
                guard let self else { return }
                self.statusBar.townInvites = invites
                self.townNotifier.update(invites)
            }
            .store(in: &cancellables)

        pollingService.$authFailed
            .receive(on: RunLoop.main)
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                DebugLog.shared.log("Primary key rejected (403) — attempting in-place recovery")
                Task { @MainActor in
                    guard let key = self.keychainService.readAPIKeyOrConfig() else {
                        self.destructiveSignOut()
                        return
                    }
                    let outcome = await self.authRecovery.handleAuthFailure(sourceType: "claude-code", apiKey: key)
                    switch outcome {
                    case .failedReauth:
                        self.destructiveSignOut()
                    case .reminted:
                        break  // recoveryRemint already re-armed polling with the new key
                    default:
                        // Recoverable/transient (healedExternally, skippedCapped, skippedInFlight, failedRemint):
                        // the poller was stopped on the 403 — re-arm it so the next cycle retries.
                        self.pollingService.authFailed = false
                        self.pollingService.start(apiKey: key)
                    }
                }
            }
            .store(in: &cancellables)

        awsCosts.$connections
            .receive(on: RunLoop.main)
            .sink { [weak self] connections in
                guard let self else { return }
                self.statusBar.awsConnected = !connections.isEmpty
                self.statusBar.awsLoginCount = connections.count
                self.statusBar.updateDisplay()
            }
            .store(in: &cancellables)

        awsCosts.$showsTotalInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] shows in
                guard let self else { return }
                self.statusBar.costInMenuBar = shows
                self.statusBar.updateDisplay()
            }
            .store(in: &cancellables)

        // What the logins cover is learned from free checks and from each refresh, so the
        // AWS page's note follows any change in the service.
        awsCosts.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.statusBar.awsNote = self.awsCosts.pageNote
            }
            .store(in: &cancellables)

        // The menu bar total follows each new reading.
        awsCosts.monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusBar.updateDisplay() }
            .store(in: &cancellables)

        clientPolicyService.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] policy in
                guard let self else { return }
                self.statusBar.clientPolicy = policy
                self.statusBar.updateDisplay()
            }
            .store(in: &cancellables)

        statusBar.onPolicyDownload = { url in
            if let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
        }

    }

    private func migrateFromRobocog() {
        // Migrate keychain credentials from old service name
        let oldKeychain = KeychainService(serviceName: "com.robocog.mac")
        if let oldKey = try? oldKeychain.getAPIKey() {
            try? keychainService.saveAPIKey(oldKey)
            if let oldKeyId = try? oldKeychain.getAPIKeyId() {
                try? keychainService.saveAPIKeyId(oldKeyId)
            }
            if let oldTokens = try? oldKeychain.getTokens() {
                try? keychainService.saveTokens(idToken: oldTokens.idToken, refreshToken: oldTokens.refreshToken)
            }
            try? oldKeychain.deleteAll()
            DebugLog.shared.log("Migrated keychain credentials from com.robocog.mac to com.lobsterone.mac")
        }

        // Migrate config file from ~/.robocog to ~/.lobsterone
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let oldConfigPath = home.appendingPathComponent(".robocog/config.json")
        let newConfigDir = home.appendingPathComponent(".lobsterone")
        let newConfigPath = newConfigDir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: oldConfigPath.path),
           !FileManager.default.fileExists(atPath: newConfigPath.path) {
            do {
                try FileManager.default.createDirectory(at: newConfigDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: oldConfigPath, to: newConfigPath)
                DebugLog.shared.log("Migrated config from ~/.robocog/config.json to ~/.lobsterone/config.json")
            } catch {
                DebugLog.shared.log("Failed to migrate config: \(error)")
            }
        }
    }

    private func startMonitoring(apiKey: String) {
        activityMonitor.start()
        pollingService.start(apiKey: apiKey)
        if configService.isCodexConfigured(), let codexKey = configService.readCodexAPIKey() {
            if configService.codexConfigNeedsTraceExporterOff() {
                do {
                    try configService.writeCodexConfig(apiKey: codexKey)
                    DebugLog.shared.log("Re-wrote Codex config with trace_exporter = \"none\"")
                } catch {
                    DebugLog.shared.log("Failed to turn off Codex trace_exporter: \(error)")
                }
            }
            codexScanner.start(apiKey: codexKey)
        }
        if configService.isMistralVibeConfigured(), let vibeKey = configService.readMistralVibeAPIKey() {
            mistralVibeScanner.start(apiKey: vibeKey)
        }
        claudeScanner.start(apiKey: apiKey)
        pushRegistration.start(apiKey: apiKey)
        // Only the screensaver listens, so there is nothing to announce without it.
        if ScreensaverWatch.isInstalled { liveActivity.start() }
        startConfigWatcher()
        // Checks hourly whether the daily AWS refresh is due; does nothing until AWS is connected.
        awsCosts.monitor.startDailySchedule()
        Task { await awsCosts.refreshIdentities() }

        // Start Anthropic quota polling — runs alongside PollingService
        let client = APIClient()
        client.setAPIKey(apiKey)
        pollingService.onPollCycleStarted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.anthropicQuotaService.fetch(syncTo: client, apiKey: apiKey)
            }
        }
        // Initial fetch
        Task {
            await anthropicQuotaService.fetch(syncTo: client, apiKey: apiKey)
        }
    }

    private func startConfigWatcher() {
        configWatcher = ConfigWatcher { [weak self] newKey in
            guard let self, let newKey else { return }
            if let currentKey = try? self.keychainService.getAPIKey(), currentKey != newKey {
                try? self.keychainService.saveAPIKey(newKey)
                self.pollingService.stop()
                self.pollingService.start(apiKey: newKey)
            }
        }
        configWatcher?.start()
    }

    /// The first-run window: sign-in, then the setup guide on a Mac that hasn't been set up.
    /// `startAt: .tools` reopens the guide for someone signed in, from Settings.
    private func showSetupWizard(startAt: SetupGuide.Step = .signIn) {
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let guide = SetupGuide(env: makeSetupGuideEnvironment(), startAt: startAt)
        if startAt > .signIn { Task { await guide.detectTools() } }
        let wizardView = SetupWizard(
            guide: guide,
            dictation: dictation,
            onSignedIn: { [weak self] in
                // Monitoring starts as soon as the keys are saved, so closing the window
                // part-way through the guide leaves a working app.
                guard let self, let apiKey = try? self.keychainService.getAPIKey() else { return }
                self.startMonitoring(apiKey: apiKey)
            },
            onFinish: { [weak self] openAWS in
                self?.setupWindow?.orderOut(nil)
                self?.setupWindow = nil
                if openAWS { self?.showSettings(tab: .aws) }
            }
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SetupWizard.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: wizardView)
        window.title = "LobsterOne Setup"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PopoverPalette.backgroundNS
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        setupWindow = window
    }

    /// The guide's way out to the Mac, through the same calls Settings makes.
    private func makeSetupGuideEnvironment() -> SetupGuide.Environment {
        SetupGuide.Environment(
            detectTools: {
                // On the main actor, where ConfigService lives. The `which` checks take a few
                // milliseconds, and the guide shows its "Looking for tools" line before this runs.
                let config = ConfigService()
                let connected = Set(config.configuredSources().map(\.type))
                let installed: [SetupGuide.Tool: Bool] = [
                    .claudeCode: config.isClaudeCodeInstalled(),
                    .codex: config.isCodexInstalled(),
                    .mistralVibe: config.isVibeInstalled(),
                ]
                return Dictionary(uniqueKeysWithValues: SetupGuide.Tool.allCases.map {
                    ($0, SetupGuide.ToolPresence(installed: installed[$0] ?? false,
                                                 connected: connected.contains($0.rawValue)))
                })
            },
            connectTool: { [weak self] tool in try await self?.addSource(tool.rawValue) },
            disconnectTool: { [weak self] tool in self?.removeSource(tool.rawValue) },
            previewSound: { entry, volume in SoundCueInstaller.preview(entry, volume: volume) },
            dictationEnabled: { DictationController.isEnabled },
            setDictationEnabled: { [weak self] on in self?.dictation.setEnabled(on) },
            selectedMicrophone: { DictationMicrophones.selectedUID },
            setMicrophone: { DictationMicrophones.selectedUID = $0 },
            paceAlertsEnabled: { PaceNotifier.isEnabled },
            setPaceAlertsEnabled: { PaceNotifier.isEnabled = $0 },
            notificationPermission: { await PaceNotifier.permission() },
            requestNotificationPermission: { await PaceNotifier.requestPermission() },
            screensaverAvailable: { ScreensaverInstaller.bundledURL != nil || ScreensaverInstaller.isInstalled },
            screensaverInstalled: { ScreensaverInstaller.isInstalled },
            screensaverStyle: { ScreensaverInstaller.chosenStyle },
            setScreensaverStyle: { [weak self] style in self?.screensaverStyleChanged(style) },
            installScreensaver: { [weak self] in
                try ScreensaverInstaller.install()
                self?.liveActivity.start()
                if ScreensaverSystemState.read().choice != .lobsterOne { ScreensaverInstaller.openScreenSaverSettings() }
            },
            awsConnected: { [weak self] in self?.awsCosts.isConnected ?? false },
            claudeCodeMod: { await ClaudeCodeMod.live().state() },
            addClaudeCodeMod: {
                let mod = ClaudeCodeMod.live()
                if case .switchedOff = await mod.state() { try await mod.turnOn() } else { try await mod.install() }
            }
        )
    }

    /// Settings' design picker and the setup guide: the snapshot carries the new design.
    private func screensaverStyleChanged(_ style: ScreensaverStyle) {
        ScreensaverInstaller.chosenStyle = style
        screensaverSnapshot.style = style
        Task { await refreshScreensaverLeaderboard(force: true) }
    }

    /// Opens Settings, or brings it forward, on the given tab (or the last one shown).
    private func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsRouter.tab = tab }
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let diagnosticsView = DiagnosticsView(
            runChecks: { [weak self] in
                await self?.runDiagnosticChecks() ?? DiagnosticCheck.initial()
            },
            onFix: { [weak self] checkId in
                await self?.fixDiagnosticIssue(checkId: checkId)
            },
            onForceRescan: { [weak self] in
                guard let self else { return }
                await self.claudeScanner.forceRescan()
                if self.configService.isCodexConfigured() {
                    await self.codexScanner.forceRescan()
                }
                if self.configService.isMistralVibeConfigured() {
                    await self.mistralVibeScanner.forceRescan()
                }
            }
        )

        var settingsView = SettingsView(
            router: settingsRouter,
            sourceStatuses: statusBar.sourceStatuses,
            onDisconnect: { [weak self] sourceType in
                self?.disconnectSource(sourceType)
            },
            onAddTool: { [weak self] sourceType in
                guard let self else { return }
                try await self.addSource(sourceType)
            },
            onRefreshSources: { [weak self] in
                await self?.fetchSourceStatuses() ?? []
            }
        )
        settingsView.diagnostics = diagnosticsView
        settingsView.dictation = dictation
        settingsView.account = settingsAccount()
        settingsView.awsCosts = awsCosts
        settingsView.onSignOut = { [weak self] in
            self?.settingsWindow?.close()
            self?.signOut()
        }
        settingsView.onCheckForUpdates = { [weak self] in
            self?.checkForUpdatesOnRequest()
        }
        settingsView.onScreensaverStyleChanged = { [weak self] style in
            self?.screensaverStyleChanged(style)
        }
        settingsView.onRunSetupGuide = { [weak self] in
            // Closed first: its pages hold what they read when they opened, and the guide changes it.
            self?.settingsWindow?.close()
            self?.showSetupWizard(startAt: .tools)
        }
        settingsView.onTownInvitesChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled, let key = self.keychainService.readAPIKeyOrConfig() {
                self.pushRegistration.start(apiKey: key)
                self.pollingService.refreshNotificationCount()
            } else if !enabled {
                self.townNotifier.removeAll()
                Task { await self.pushRegistration.unregister() }
            }
        }
        settingsView.onScreensaverChanged = { [weak self] installed in
            guard let self else { return }
            if installed { self.liveActivity.start() } else { self.liveActivity.stop() }
        }

        // Same warm look as the popover, title bar included. One size for every tab, so the
        // window stays put when you switch; SwiftUI doesn't size the window itself.
        let host = NSHostingController(rootView: settingsView)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PopoverPalette.backgroundNS
        window.isReleasedWhenClosed = false
        // The app's one window size; shorter only when the screen is, and the pages scroll then.
        window.setContentSize(AppWindow.fitted)
        // The title follows the tab, as in System Settings.
        settingsTitleCancellable = settingsRouter.$tab
            .receive(on: RunLoop.main)
            .sink { [weak window] tab in window?.title = tab.title }
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Only while the leaderboard design is chosen and the screensaver is installed.
    private func refreshScreensaverLeaderboard(force: Bool = false) async {
        guard ScreensaverInstaller.isInstalled, ScreensaverInstaller.chosenStyle == .leaderboard else { return }
        if let board = await screensaverLeaderboard.fetch(force: force) {
            screensaverSnapshot.leaderboard = board
        }
    }

    /// Who's signed in and what this Mac reports with, for the Account tab.
    private func settingsAccount() -> SettingsAccount {
        let idToken = (try? keychainService.getTokens())?.idToken
        let key = try? keychainService.getAPIKey()
        return SettingsAccount(
            email: idToken.flatMap(AuthService.email(fromIDToken:)),
            claudePlan: anthropicQuotaService.state.planLabel,
            keyPrefix: key.map { String($0.prefix(11)) }
        )
    }

    // MARK: - Diagnostic Checks

    private func runDiagnosticChecks() async -> [DiagnosticCheck] {
        var checks = DiagnosticCheck.initial()

        // Shell check
        let affectedFiles = configService.scanShellProfiles()
        if affectedFiles.isEmpty {
            checks[0].status = .passed("No shell OTEL exports found")
        } else {
            checks[0].status = .warning("OTEL exports found in: \(affectedFiles.joined(separator: ", "))")
        }

        // Claude Code check
        let claudeOtel = configService.checkClaudeCodeOtel()
        if claudeOtel.configured {
            let endpoint = claudeOtel.endpoint ?? ""
            let correctEndpoint = endpoint == Constants.ingestURL
            if correctEndpoint {
                checks[1].status = .passed("Configured with key \(claudeOtel.keyPrefix ?? "")")
            } else {
                checks[1].status = .warning("Wrong endpoint: \(endpoint)")
            }
        } else {
            checks[1].status = .failed("Not configured")
        }

        // Codex check
        let codexInstalled = configService.isCodexInstalled()
        DebugLog.shared.log("Diagnostics: codexInstalled=\(codexInstalled)")
        if codexInstalled {
            let codexOtel = configService.checkCodexOtel()
            DebugLog.shared.log("Diagnostics: codexOtel configured=\(codexOtel.configured) endpoint=\(codexOtel.endpoint ?? "nil") keyPrefix=\(codexOtel.keyPrefix ?? "nil")")
            if !codexOtel.configured {
                let raw = (try? String(contentsOf: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
                DebugLog.shared.log("Diagnostics: codex config.toml exists=\(!raw.isEmpty) bytes=\(raw.count) hasOtelExporter=\(raw.contains("[otel.exporter.otlp-http]")) hasRcKey=\(raw.contains("'rc_") || raw.contains("\"rc_"))")
            }
            if codexOtel.configured {
                let endpoint = codexOtel.endpoint ?? ""
                let correctEndpoint = endpoint.hasPrefix(Constants.ingestURL)
                if correctEndpoint {
                    checks[2].status = .passed("Configured with key \(codexOtel.keyPrefix ?? "")")
                } else {
                    checks[2].status = .warning("Wrong endpoint: \(endpoint)")
                }
            } else {
                checks[2].status = .failed("Not configured")
            }
        } else {
            checks[2].status = .skipped("Codex not installed")
        }

        // Keys check — validate each configured source's API key against the backend
        let sources = configService.configuredSources()
        var statusBySource: [String: InstanceStatusResponse] = [:]
        if sources.isEmpty {
            checks[3].status = .skipped("No sources configured")
        } else {
            let apiClient = APIClient()
            var allValid = true
            var failedSources: [String] = []
            for source in sources {
                do {
                    // Any successful 2xx from /v1/instance/status means the backend
                    // accepted the key. Status values "active" (has data today),
                    // "connected_no_data" (used at some point), and "unknown" (newly
                    // minted, never used) are all valid — only an HTTP error means
                    // the key is rejected.
                    let status = try await apiClient.fetchInstanceStatus(apiKey: source.apiKey)
                    statusBySource[source.type] = status
                    DebugLog.shared.log("Key check \(source.displayName): \(status.status) hasOtelData=\(status.hasOtelData.map(String.init) ?? "n/a")")
                } catch {
                    allValid = false
                    failedSources.append(source.displayName)
                    DebugLog.shared.log("Key check \(source.displayName) failed: \(error)")
                }
            }
            if allValid {
                checks[3].status = .passed("All \(sources.count) key(s) accepted by backend")
            } else {
                checks[3].status = .failed("Rejected keys: \(failedSources.joined(separator: ", "))")
            }
        }

        // Endpoints check — composite of claude-code and codex endpoint correctness
        let claudeEndpointOk = claudeOtel.configured && claudeOtel.endpoint == Constants.ingestURL
        let codexOtel = configService.checkCodexOtel()
        let codexEndpointOk = !codexInstalled || (codexOtel.configured && (codexOtel.endpoint ?? "").hasPrefix(Constants.ingestURL))

        if claudeEndpointOk && codexEndpointOk {
            checks[4].status = .passed("All endpoints point to ingest.lobsterone.ai")
        } else if !claudeOtel.configured && !codexOtel.configured {
            checks[4].status = .skipped("No tools configured")
        } else {
            var bad: [String] = []
            if claudeOtel.configured && !claudeEndpointOk { bad.append("Claude Code") }
            if codexInstalled && codexOtel.configured && !codexEndpointOk { bad.append("Codex") }
            if bad.isEmpty {
                checks[4].status = .passed("All endpoints correct")
            } else {
                checks[4].status = .warning("Wrong endpoint for: \(bad.joined(separator: ", "))")
            }
        }

        // Telemetry delivery check — has the backend EVER received metric data
        // from each configured source? Local config can be correct while the
        // tool never exports (env overrides beat settings.json, stale
        // processes keep old env). This is the check the config checks can't do.
        if sources.isEmpty {
            checks[5].status = .skipped("No sources configured")
        } else if statusBySource.isEmpty {
            checks[5].status = .skipped("Could not reach backend")
        } else {
            var receiving: [String] = []
            var neverReceived: [String] = []
            for source in sources {
                guard let status = statusBySource[source.type] else { continue }
                // Older backends don't return has_otel_data — fall back to
                // status, where "unknown" means no data ever received.
                let hasData = status.hasOtelData ?? (status.status != "unknown")
                if hasData {
                    receiving.append(source.displayName)
                } else {
                    neverReceived.append(source.displayName)
                }
            }
            if neverReceived.isEmpty {
                checks[5].status = .passed("Backend is receiving data from \(receiving.joined(separator: ", "))")
            } else {
                var msg = "\(neverReceived.joined(separator: ", ")): configured, but the backend has never received telemetry."
                if neverReceived.contains("Claude Code") {
                    let overrides = configService.scanTelemetryOverrides()
                    if !overrides.isEmpty {
                        msg += " Possible cause: \(overrides.joined(separator: "; "))."
                    } else {
                        msg += " Start a fresh Claude Code session (settings are read at launch). If it persists, check for OTEL or telemetry overrides in your shell or project config."
                    }
                }
                checks[5].status = .warning(msg)
            }
        }

        return checks
    }

    // MARK: - Diagnostic Fixes

    /// Returns nil on success, or an error message string on failure.
    private func fixDiagnosticIssue(checkId: String) async -> String? {
        switch checkId {
        case "shell":
            let affectedFiles = configService.scanShellProfiles()
            for filename in affectedFiles {
                do {
                    try configService.removeShellOtelExports(from: filename)
                    DebugLog.shared.log("Removed OTEL exports from \(filename)")
                } catch {
                    return "Failed to fix \(filename): \(error.localizedDescription)"
                }
            }
            return nil

        case "claude-code":
            guard let apiKey = try? keychainService.getAPIKey() else {
                return "No API key in keychain — sign out and sign in again"
            }
            do {
                try configService.writeConfig(apiKey: apiKey)
                DebugLog.shared.log("Re-wrote Claude Code config")
                return nil
            } catch {
                return "Failed to write Claude Code config: \(error.localizedDescription)"
            }

        case "codex":
            // Try to reuse the existing codex key if already present
            if let existingKey = configService.readCodexAPIKey() {
                do {
                    try configService.writeCodexConfig(apiKey: existingKey)
                    DebugLog.shared.log("Re-wrote Codex config with existing key")
                    return nil
                } catch {
                    return "Failed to write Codex config: \(error.localizedDescription)"
                }
            }
            // No existing codex key — create a new one via auth refresh
            guard let tokens = try? keychainService.getTokens() else {
                return "Not signed in — sign out and sign in again"
            }
            let idToken: String
            do {
                let refreshed = try await authService.refreshTokens(refreshToken: tokens.refreshToken)
                idToken = refreshed.id_token
                try? keychainService.saveTokens(idToken: refreshed.id_token, refreshToken: tokens.refreshToken)
                DebugLog.shared.log("Codex fix: token refresh succeeded")
            } catch {
                DebugLog.shared.log("Codex fix: token refresh failed (\(error)) — falling back to stored idToken")
                idToken = tokens.idToken
            }
            let apiClient = APIClient()
            do {
                let newKey = try await authService.createAPIKeyWithRetry(
                    apiClient: apiClient,
                    idToken: idToken,
                    label: "LobsterOne Mac App — Codex",
                    sourceType: "codex"
                )
                try configService.writeCodexConfig(apiKey: newKey.key)
                DebugLog.shared.log("Created and wrote new Codex API key")
                return nil
            } catch APIError.httpError(statusCode: 401, _) {
                DebugLog.shared.log("Codex fix: 401 from /v1/api-keys — triggering re-auth")
                return await reauthAndCreateCodexKey(apiClient: apiClient)
            } catch {
                DebugLog.shared.log("Create Codex API key failed: \(error)")
                return "Failed to create Codex API key: \(error.localizedDescription)"
            }

        case "keys":
            var failures: [String] = []
            for source in configService.configuredSources() {
                let outcome = await authRecovery.handleAuthFailure(sourceType: source.type, apiKey: source.apiKey)
                if outcome == .failedReauth || outcome == .failedRemint {
                    failures.append(source.displayName)
                }
            }
            return failures.isEmpty ? nil : "Could not recover: \(failures.joined(separator: ", "))"

        case "endpoints":
            // Re-write configs with the correct endpoint for any misconfigured sources
            let claudeOtel = configService.checkClaudeCodeOtel()
            if claudeOtel.configured, claudeOtel.endpoint != Constants.ingestURL {
                guard let apiKey = try? keychainService.getAPIKey() else {
                    return "No API key in keychain for Claude Code"
                }
                do {
                    try configService.writeConfig(apiKey: apiKey)
                    DebugLog.shared.log("Re-wrote Claude Code config to fix endpoint")
                } catch {
                    return "Failed to fix Claude Code endpoint: \(error.localizedDescription)"
                }
            }
            let codexOtel = configService.checkCodexOtel()
            if codexOtel.configured, let ep = codexOtel.endpoint, !ep.hasPrefix(Constants.ingestURL) {
                guard let codexKey = configService.readCodexAPIKey() else {
                    return "No Codex API key found"
                }
                do {
                    try configService.writeCodexConfig(apiKey: codexKey)
                    DebugLog.shared.log("Re-wrote Codex config to fix endpoint")
                } catch {
                    return "Failed to fix Codex endpoint: \(error.localizedDescription)"
                }
            }
            return nil

        default:
            return "Unknown check ID: \(checkId)"
        }
    }

    /// Run the OAuth sign-in flow, persist fresh tokens, and retry creating a codex API key.
    /// Called when the codex Fix path 401s — typically because the stored Cognito refresh
    /// token has expired (>30 days since last sign-in) and the user needs a new session.
    private func reauthAndCreateCodexKey(apiClient: APIClient) async -> String? {
        let result: AuthService.AuthResult
        do {
            result = try await authService.signIn()
            try keychainService.saveTokens(idToken: result.idToken, refreshToken: result.refreshToken)
            DebugLog.shared.log("Codex fix: re-auth succeeded as \(result.email ?? "unknown")")
        } catch AuthError.cancelled {
            DebugLog.shared.log("Codex fix: re-auth cancelled by user")
            return "Sign-in cancelled — try again"
        } catch {
            DebugLog.shared.log("Codex fix: re-auth failed: \(error)")
            return "Sign in failed: \(error.localizedDescription)"
        }

        do {
            let newKey = try await authService.createAPIKeyWithRetry(
                apiClient: apiClient,
                idToken: result.idToken,
                label: "LobsterOne Mac App — Codex",
                sourceType: "codex"
            )
            try configService.writeCodexConfig(apiKey: newKey.key)
            DebugLog.shared.log("Created and wrote new Codex API key after re-auth")
            return nil
        } catch {
            DebugLog.shared.log("Create Codex API key failed after re-auth: \(error)")
            return "Failed to create Codex API key: \(error.localizedDescription)"
        }
    }

    // MARK: - In-place auth recovery (Layer 2)

    /// Re-check a key against the backend. true = accepted (heal not needed).
    private func recoveryValidateKey(_ apiKey: String) async -> Bool {
        let apiClient = APIClient()
        do { _ = try await apiClient.fetchInstanceStatus(apiKey: apiKey); return true }
        catch { return false }
    }

    /// Refresh the Cognito session in place, preserving the refresh token. true = valid.
    private func recoveryRefreshSession() async -> Bool {
        guard let tokens = try? keychainService.getTokens() else { return false }
        do {
            let refreshed = try await authService.refreshTokens(refreshToken: tokens.refreshToken)
            try? keychainService.saveTokens(idToken: refreshed.id_token, refreshToken: tokens.refreshToken)
            return true
        } catch {
            return false
        }
    }

    /// Interactive OAuth sign-in that persists tokens WITHOUT deleting keys/config.
    private func recoveryReauthenticate() async -> Bool {
        do {
            let result = try await authService.signIn()
            try keychainService.saveTokens(idToken: result.idToken, refreshToken: result.refreshToken)
            return true
        } catch {
            DebugLog.shared.log("Auth recovery re-auth failed: \(error)")
            return false
        }
    }

    /// Mint a fresh key for the source, write its config, and restart its scanner.
    /// For claude-code this also updates the keychain primary key and restarts polling.
    private func recoveryRemint(sourceType: String) async -> Bool {
        guard let tokens = try? keychainService.getTokens() else { return false }
        let idToken: String
        do {
            let refreshed = try await authService.refreshTokens(refreshToken: tokens.refreshToken)
            idToken = refreshed.id_token
            try? keychainService.saveTokens(idToken: refreshed.id_token, refreshToken: tokens.refreshToken)
        } catch {
            idToken = tokens.idToken
        }
        let displayName = sourceDisplayName(sourceType)
        let apiClient = APIClient()
        do {
            let newKey = try await authService.createAPIKeyWithRetry(
                apiClient: apiClient, idToken: idToken,
                label: "LobsterOne Mac App — \(displayName)", sourceType: sourceType)
            switch sourceType {
            case "claude-code":
                try keychainService.saveAPIKey(newKey.key)
                try keychainService.saveAPIKeyId(newKey.id)
                try configService.writeConfig(apiKey: newKey.key)
                pollingService.authFailed = false
                pollingService.start(apiKey: newKey.key)
                claudeScanner.start(apiKey: newKey.key)
            case "codex":
                try configService.writeCodexConfig(apiKey: newKey.key)
                codexScanner.start(apiKey: newKey.key)
            case "mistral-vibe":
                try configService.writeMistralVibeConfig(apiKey: newKey.key)
                mistralVibeScanner.start(apiKey: newKey.key)
            default:
                return false
            }
            return true
        } catch {
            DebugLog.shared.log("Auth recovery remint failed for \(sourceType): \(error)")
            return false
        }
    }

    /// Build the live environment for `AuthRecoveryCoordinator`.
    private func makeRecoveryEnvironment() -> ClosureAuthRecoveryEnvironment {
        ClosureAuthRecoveryEnvironment(
            waitForHealGrace: { try? await Task.sleep(nanoseconds: 10_000_000_000) }, // 10s debounce
            validateKey: { [weak self] key in await self?.recoveryValidateKey(key) ?? false },
            refreshSession: { [weak self] in await self?.recoveryRefreshSession() ?? false },
            reauthenticate: { [weak self] in await self?.recoveryReauthenticate() ?? false },
            remintKey: { [weak self] src in await self?.recoveryRemint(sourceType: src) ?? false },
            now: { Date() },
            log: { msg in Task { @MainActor in DebugLog.shared.log(msg) } }
        )
    }

    /// Last-resort fallback: the pre-existing destructive sign-out + wizard.
    private func destructiveSignOut() {
        DebugLog.shared.log("Auth recovery exhausted — clearing credentials and showing setup wizard")
        try? keychainService.deleteAll()
        screensaverSnapshot.remove()
        townNotifier.removeAll()
        statusBar.townInvites = []
        configWatcher?.stop()
        configWatcher = nil
        stopAWSCosts()
        showSetupWizard()
    }

    /// AWS keys must not outlive a LobsterOne sign-out, so signing out disconnects AWS too.
    private func stopAWSCosts() {
        awsCosts.monitor.stop()
        awsCosts.disconnectAll()
    }

    private func fetchSourceStatuses() async -> [SourceStatus] {
        let sources = configService.configuredSources()
        guard !sources.isEmpty else { return [] }

        let apiClient = APIClient()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return await withTaskGroup(of: SourceStatus.self, returning: [SourceStatus].self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    var lastSeen: Date? = nil
                    var tokens = 0
                    var backendStatus: String? = nil
                    var percentUsed: Double = 0
                    do {
                        let status = try await apiClient.fetchInstanceStatus(apiKey: source.apiKey)
                        backendStatus = status.status
                        if let lastSeenStr = status.lastSeenAt {
                            lastSeen = iso.date(from: lastSeenStr)
                        }
                        tokens = status.today.totalTokens
                        DebugLog.shared.log("Instance status \(source.displayName): \(status.status), tokens=\(tokens)")

                        // Fetch per-instance quota using the instance ID
                        do {
                            let quota = try await apiClient.fetchQuotaForInstance(apiKey: source.apiKey, instanceId: status.instanceId)
                            percentUsed = quota.percentUsed
                            DebugLog.shared.log("Instance quota \(source.displayName): \(percentUsed)%")
                        } catch {
                            DebugLog.shared.log("Instance quota \(source.displayName) failed: \(error)")
                        }
                    } catch {
                        DebugLog.shared.log("Instance status \(source.displayName) failed: \(error)")
                        if case APIError.httpError(let code, _) = error, code == 401 || code == 403 {
                            let type = source.type, key = source.apiKey
                            Task { [weak self] in
                                await self?.authRecovery.handleAuthFailure(sourceType: type, apiKey: key)
                            }
                        }
                    }
                    return SourceStatus(
                        id: source.type,
                        displayName: source.displayName,
                        keyPrefix: source.keyPrefix,
                        lastSeenAt: lastSeen,
                        todayTokens: tokens,
                        backendStatus: backendStatus,
                        isConfigured: true,
                        percentUsed: percentUsed
                    )
                }
            }

            var results: [SourceStatus] = []
            for await status in group {
                results.append(status)
            }
            // Maintain consistent ordering: claude-code first, codex second
            return results.sorted { $0.id < $1.id }
        }
    }

    private func disconnectSource(_ sourceType: String) {
        let displayName = sourceDisplayName(sourceType)
        let alert = NSAlert()
        alert.messageText = "Disconnect \(displayName)?"
        alert.informativeText = "This will remove LobsterOne telemetry config from \(displayName)."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeSource(sourceType)
    }

    /// Takes LobsterOne's config out of a tool and stops reading it.
    private func removeSource(_ sourceType: String) {
        let displayName = sourceDisplayName(sourceType)
        do {
            switch sourceType {
            case "claude-code":
                try configService.removeConfig()
            case "codex":
                try configService.removeCodexConfig()
                codexScanner.stop()
            case "mistral-vibe":
                configService.removeMistralVibeConfig()
                mistralVibeScanner.stop()
            default:
                break
            }
            DebugLog.shared.log("Disconnected \(displayName)")
        } catch {
            DebugLog.shared.log("Failed to disconnect \(displayName): \(error)")
        }
    }

    private func sourceDisplayName(_ sourceType: String) -> String {
        switch sourceType {
        case "codex": return "Codex"
        case "mistral-vibe": return "Mistral Vibe"
        default: return "Claude Code"
        }
    }

    private func addSource(_ sourceType: String) async throws {
        guard let tokens = try? keychainService.getTokens() else {
            throw NSError(domain: "LobsterOne", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in. Sign out and sign in again."])
        }

        // Refresh the id token — it may have expired since initial login
        let idToken: String
        do {
            let refreshed = try await authService.refreshTokens(refreshToken: tokens.refreshToken)
            idToken = refreshed.id_token
            try? keychainService.saveTokens(idToken: refreshed.id_token, refreshToken: tokens.refreshToken)
        } catch {
            // Fallback to stored token — may still work if recently refreshed
            idToken = tokens.idToken
        }

        let displayName = sourceDisplayName(sourceType)
        let label = "LobsterOne Mac App — \(displayName)"
        let apiClient = APIClient()

        let newKey = try await authService.createAPIKeyWithRetry(
            apiClient: apiClient,
            idToken: idToken,
            label: label,
            sourceType: sourceType
        )

        switch sourceType {
        case "claude-code":
            // claudeScanner is started unconditionally in startMonitoring() and is
            // always running by the time this menu is reachable — only write config.
            try configService.writeConfig(apiKey: newKey.key)
        case "codex":
            try configService.writeCodexConfig(apiKey: newKey.key)
            codexScanner.start(apiKey: newKey.key)
        case "mistral-vibe":
            try configService.writeMistralVibeConfig(apiKey: newKey.key)
            mistralVibeScanner.start(apiKey: newKey.key)
        default:
            break
        }

        DebugLog.shared.log("Added \(displayName) with key \(newKey.keyPrefix)...")
    }

    private func signOut() {
        pollingService.stop()
        codexScanner.stop()
        mistralVibeScanner.stop()
        claudeScanner.stop()
        liveActivity.stop()
        activityMonitor.stop()
        configWatcher?.stop()
        configWatcher = nil

        if let apiKeyId = try? keychainService.getAPIKeyId(),
           let apiKey = try? keychainService.getAPIKey() {
            let client = APIClient(apiKey: apiKey)
            Task {
                // Before the key goes: this Mac must stop getting the old account's invites.
                await self.pushRegistration.unregister(apiKey: apiKey)
                do {
                    try await client.revokeAPIKey(id: apiKeyId)
                } catch {
                    print("[LobsterOne] Warning: Failed to revoke API key server-side: \(error)")
                }
            }
        }

        try? keychainService.deleteAll()
        screensaverSnapshot.remove()
        townNotifier.removeAll()
        statusBar.townInvites = []
        stopAWSCosts()

        let alert = NSAlert()
        alert.messageText = "Remove telemetry config?"
        alert.informativeText = "Also remove LobsterOne telemetry config from your AI coding tools?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Keep")
        if alert.runModal() == .alertFirstButtonReturn {
            try? configService.removeConfig()
            try? configService.removeCodexConfig()
            configService.removeMistralVibeConfig()
        }

        showSetupWizard()
    }
}

// MARK: - Apple push (town invites)
extension AppDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pushRegistration.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushRegistration.didFail(error)
    }

    /// Alert pushes (an invite) and background pushes (`town_clear`) both land here while the
    /// app runs. Either way the count call then refreshes the popover row and the bell badge.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if let cleared = PushRegistration.clearedInviteIds(userInfo) {
            townNotifier.remove(inviteIds: cleared)
            statusBar.townInvites.removeAll { cleared.contains($0.inviteId) }
        } else if let inviteId = userInfo["invite_id"] as? String, !inviteId.isEmpty {
            townNotifier.admitPush(inviteId: inviteId)
        }
        pollingService.refreshNotificationCount()
    }
}

// MARK: - Sparkle Delegate
extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        DebugLog.shared.log("Sparkle loaded appcast with \(appcast.items.count) item(s)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = item.versionString
        DebugLog.shared.log("Sparkle found update \(version) (\(build))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        DebugLog.shared.log("Sparkle did not find an update: \(error.localizedDescription)")
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        DebugLog.shared.log(
            "Sparkle: update \(item.displayVersionString) (\(item.versionString)) ready, waiting for idle"
        )
        updateGate.hold(immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willShowModalAlert alert: NSAlert) {
        promoteAppForUpdateUI()
    }

    func updater(_ updater: SPUUpdater, didDismissModalAlert alert: NSAlert) {
        restoreAppAfterUpdateUI()
    }
}

// MARK: - Sparkle User Driver Delegate
extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    func standardUserDriverWillShowModalAlert() {
        promoteAppForUpdateUI()
    }

    func standardUserDriverDidShowModalAlert() {
        promoteAppForUpdateUI()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        promoteAppForUpdateUI()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restoreAppAfterUpdateUI()
    }
}

private extension AppDelegate {
    /// "Check for Updates" from the popover or About. An update that already downloaded is
    /// waiting for the person to step away; asking is a clear yes, so install it now. Sparkle
    /// shows nothing for a fresh check while an update is held, which made the button look dead.
    func checkForUpdatesOnRequest() {
        if updateGate.installNow() { return }
        promoteAppForUpdateUI()
        updaterController.checkForUpdates(nil)
    }

    func promoteAppForUpdateUI() {
        guard !updateUIPromotedApp else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        updateUIPromotedApp = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func restoreAppAfterUpdateUI() {
        guard updateUIPromotedApp else { return }
        updateUIPromotedApp = false
        NSApp.setActivationPolicy(.accessory)
    }
}

extension KeychainService {
    func readAPIKeyOrConfig() -> String? {
        if let key = try? getAPIKey() { return key }
        return ConfigService().readAPIKey()
    }
}
