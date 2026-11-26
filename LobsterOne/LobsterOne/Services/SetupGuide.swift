import Combine
import Foundation

/// The guide that follows sign-in: one optional feature per screen, each with a default and a
/// way to leave it for later. Holds what the person picks and applies each pick, when they
/// confirm that screen, through the same calls Settings makes. "Not now" changes nothing.
@MainActor
final class SetupGuide: ObservableObject {
    enum Step: Int, CaseIterable, Comparable {
        case signIn, tools, claudeCode, sounds, dictation, alerts, screensaver, aws, done

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// "3 of 8", counting sign-in as the first.
        var number: Int { rawValue + 1 }
        static var count: Int { allCases.count }

        /// The line on the summary.
        var summaryTitle: String {
            switch self {
            case .signIn: "Account"
            case .tools: "Tools"
            case .claudeCode: "In Claude Code"
            case .sounds: "Sounds"
            case .dictation: "Dictation"
            case .alerts: "Usage cap alerts"
            case .screensaver: "Screensaver"
            case .aws: "AWS costs"
            case .done: ""
            }
        }
    }

    /// The coding tools LobsterOne tracks. Raw values are the source types the app uses.
    enum Tool: String, CaseIterable, Identifiable {
        case claudeCode = "claude-code", codex, mistralVibe = "mistral-vibe"

        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .mistralVibe: "Mistral Vibe"
            }
        }

        var soundTool: SoundTool {
            switch self {
            case .claudeCode: .claude
            case .codex: .codex
            case .mistralVibe: .vibe
            }
        }
    }

    struct ToolPresence: Equatable {
        /// Found on this Mac.
        var installed: Bool
        /// LobsterOne already reports from it.
        var connected: Bool

        /// Worth a switch: it's here, or we're already wired into it.
        var available: Bool { installed || connected }
    }

    /// What a screen came to, for the summary.
    enum Outcome: Equatable {
        case on(String)
        case off(String)
        case skipped
        case failed(String)
    }

    /// Every call the guide makes outside itself, so tests can stand in for the Mac.
    struct Environment {
        var defaults: UserDefaults = .standard
        /// Where the sound hooks are written; the person's home in the app.
        var home: URL = URL(fileURLWithPath: NSHomeDirectory())
        var detectTools: () async -> [Tool: ToolPresence]
        /// Settings' "Add tool": mints the tool's key and writes its config.
        var connectTool: (Tool) async throws -> Void
        /// Settings' "Disconnect", without its confirmation: the guide's button is the confirmation.
        var disconnectTool: (Tool) -> Void
        var previewSound: (SoundCueSettings.Entry, Double) -> Void
        var dictationEnabled: () -> Bool
        var setDictationEnabled: (Bool) -> Void
        var microphones: () -> [DictationMicrophones.Microphone] = { DictationMicrophones.available() }
        var systemMicrophoneName: () -> String? = { DictationMicrophones.systemDefaultName }
        var selectedMicrophone: () -> String?
        var setMicrophone: (String?) -> Void
        var paceAlertsEnabled: () -> Bool
        var setPaceAlertsEnabled: (Bool) -> Void
        var notificationPermission: () async -> PaceNotifier.Permission
        var requestNotificationPermission: () async -> Void
        /// False in builds that don't carry the screensaver.
        var screensaverAvailable: () -> Bool
        var screensaverInstalled: () -> Bool
        var screensaverStyle: () -> ScreensaverStyle
        var setScreensaverStyle: (ScreensaverStyle) -> Void
        /// Installs it and opens the picker in System Settings, as Settings' Install button does.
        var installScreensaver: () throws -> Void
        var awsConnected: () -> Bool
        /// What Claude Code says about the LobsterOne mod, as Settings, Tools shows it.
        var claudeCodeMod: () async -> ClaudeCodeMod.State = { .notBundled }
        /// Settings' "Add to Claude Code": adds the mod, or turns it back on.
        var addClaudeCodeMod: () async throws -> Void = {}
    }

    let env: Environment
    /// Where this run began: sign-in for a new Mac, tools when reopened from Settings.
    let firstStep: Step

    @Published private(set) var step: Step
    @Published private(set) var isApplying = false
    /// Why the last confirm didn't go through; the screen stays put while it shows.
    @Published var problem: String?
    @Published private(set) var outcomes: [Step: Outcome] = [:]

    // Tools
    /// Nil while the tools are being looked for.
    @Published private(set) var tools: [Tool: ToolPresence]?
    @Published var tracked: Set<Tool> = []

    // Sounds
    /// The chosen pack's id; nil plays no sounds.
    @Published var packID: String?

    // Dictation
    @Published var dictationOn: Bool
    /// The chosen microphone's UID; empty follows the system default.
    @Published var microphoneUID: String

    // Alerts
    @Published var paceAlertsOn: Bool
    @Published private(set) var notificationPermission: PaceNotifier.Permission?

    // Screensaver
    @Published var screensaverStyle: ScreensaverStyle
    @Published private(set) var screensaverInstalled: Bool
    let screensaverAvailable: Bool

    // Claude Code
    /// Nil until the step has asked Claude Code.
    @Published private(set) var claudeCodeMod: ClaudeCodeMod.State?

    // AWS
    @Published private(set) var wantsAWS = false
    let awsConnected: Bool

    init(env: Environment, startAt: Step = .signIn) {
        self.env = env
        self.firstStep = startAt
        self.step = startAt
        let sounds = SoundCueSettings.load(env.defaults)
        // Sounds already on keep their pack; a new Mac starts on Garry's, which is the app's own.
        self.packID = sounds.enabled ? sounds.pack?.id ?? Self.customPackID : SoundPack.all.first?.id
        self.dictationOn = env.dictationEnabled()
        self.microphoneUID = env.selectedMicrophone() ?? ""
        self.paceAlertsOn = env.paceAlertsEnabled()
        self.screensaverStyle = env.screensaverStyle()
        self.screensaverInstalled = env.screensaverInstalled()
        self.screensaverAvailable = env.screensaverAvailable()
        self.awsConnected = env.awsConnected()
        if startAt > .signIn { Self.markSeen(env.defaults) }
    }

    /// Sounds that are on with picks of the person's own, matching no pack. Kept as they are
    /// unless another choice is made.
    static let customPackID = "custom"

    // MARK: First run

    static let seenKey = "setupGuideSeen"

    /// Settings people change by hand. Any of them saved means this Mac has been set up before
    /// the guide existed, so signing in again shouldn't walk them through it.
    static let savedSetupKeys = [
        SoundCueSettings.defaultsKey, PaceNotifier.enabledKey, TownInviteNotifier.enabledKey,
        CostAlertNotifier.enabledKey, DictationController.enabledKey, DictationShortcut.defaultsKey,
        DictationMicrophones.selectedKey, "screensaverStyle", "screensaverInviteDismissed",
    ]

    static func markSeen(_ defaults: UserDefaults) {
        defaults.set(true, forKey: seenKey)
    }

    /// Whether to walk someone through the guide after they sign in: only on a Mac that has
    /// never shown it and has no settings of its own yet.
    static func shouldShowAfterSignIn(_ defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: seenKey) && !savedSetupKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// At launch. Someone already signed in set the app up before this guide existed (or saw
    /// it), so a later sign-out and sign-in mustn't bring it up.
    static func noteLaunch(signedIn: Bool, defaults: UserDefaults) {
        if signedIn { markSeen(defaults) }
    }

    /// Sign-in is done; on to the first choice.
    func begin() {
        Self.markSeen(env.defaults)
        step = .tools
        Task { await detectTools() }
    }

    func detectTools() async {
        let found = await env.detectTools()
        tools = found
        tracked = Set(Tool.allCases.filter { found[$0]?.available == true })
    }

    // MARK: Moving

    var canGoBack: Bool { step > firstStep && step > .tools && !isApplying }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        problem = nil
        step = previous
    }

    /// "Not now": leaves this one as it is. A screen that can't apply here passes its reason.
    func skip(_ outcome: Outcome = .skipped) {
        guard !isApplying else { return }
        if step == .aws { wantsAWS = false }
        outcomes[step] = outcome
        advance()
    }

    /// The primary button: applies what this screen shows, then moves on. Safe to repeat;
    /// a choice that matches what's already set changes nothing.
    func confirm() async {
        guard !isApplying, step != .signIn, step != .done else { return }
        isApplying = true
        problem = nil
        defer { isApplying = false }
        switch step {
        case .tools: await applyTools()
        case .claudeCode: await applyClaudeCode()
        case .sounds: applySounds()
        case .dictation: applyDictation()
        case .alerts: await applyAlerts()
        case .screensaver: applyScreensaver()
        case .aws: applyAWS()
        case .signIn, .done: break
        }
        if problem == nil { advance() }
    }

    private func advance() {
        problem = nil
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
        if step == .alerts, notificationPermission == nil {
            Task { notificationPermission = await env.notificationPermission() }
        }
        if step == .claudeCode, claudeCodeMod == nil {
            Task { await refreshClaudeCodeMod() }
        }
    }

    // MARK: Tools

    private func applyTools() async {
        guard var found = tools else { return }
        var failures: [String] = []
        for tool in Tool.allCases {
            guard var presence = found[tool] else { continue }
            let wanted = tracked.contains(tool)
            if wanted, !presence.connected, presence.installed {
                do {
                    try await env.connectTool(tool)
                    presence.connected = true
                } catch {
                    failures.append("\(tool.title): \(error.localizedDescription)")
                }
            } else if !wanted, presence.connected {
                env.disconnectTool(tool)
                presence.connected = false
            }
            found[tool] = presence
        }
        tools = found
        let on = Tool.allCases.filter { found[$0]?.connected == true }.map(\.title)
        if !failures.isEmpty {
            problem = "Couldn't connect \(failures.joined(separator: "; ")). Try again, or skip and add it later in Settings."
            return
        }
        outcomes[.tools] = on.isEmpty ? .off("None tracked") : .on(Self.list(on))
    }

    /// The tools sounds would play in: those tracked here, or Claude Code when none are.
    var soundTools: Set<SoundTool> {
        let chosen = Set(tracked.filter { tools?[$0]?.available == true }.map(\.soundTool))
        return chosen.isEmpty ? [.claude] : chosen
    }

    // MARK: Sounds

    var chosenPack: SoundPack? { SoundPack.all.first { $0.id == packID } }

    /// Picks a pack and plays a taste of it, as the Sounds tab does.
    func choosePack(_ id: String?) {
        packID = id
        guard let pack = chosenPack else { return }
        playSample(pack, cue: .sessionStart)
    }

    func playSample(_ pack: SoundPack, cue: SoundCue = .finished) {
        var settings = SoundCueSettings.load(env.defaults)
        settings.apply(pack)
        env.previewSound(settings.entry(cue), settings.volume(for: cue))
    }

    private func applySounds() {
        let before = SoundCueSettings.load(env.defaults)
        var settings = before
        if packID == Self.customPackID {
            // Their own mix, already on: nothing to change.
        } else if let pack = chosenPack {
            if !settings.enabled { settings.tools = soundTools }
            settings.enabled = true
            settings.apply(pack)
        } else {
            settings.enabled = false
        }
        if settings != before {
            let errors = settings.saveAndInstall(defaults: env.defaults, homeDirectory: env.home)
            if let failure = errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }).first {
                outcomes[.sounds] = .failed("\(failure.key.title): \(failure.value)")
                return
            }
        }
        if settings.enabled {
            let pack = settings.pack.map { "\($0.name) pack" } ?? "Your own picks"
            let tools = SoundTool.allCases.filter { settings.tools.contains($0) }.map(\.title)
            outcomes[.sounds] = .on("\(pack) in \(Self.list(tools))")
        } else {
            outcomes[.sounds] = .off("No sounds")
        }
    }

    // MARK: Dictation

    private func applyDictation() {
        if dictationOn {
            let uid = microphoneUID.isEmpty ? nil : microphoneUID
            if uid != env.selectedMicrophone() { env.setMicrophone(uid) }
        }
        if dictationOn != env.dictationEnabled() { env.setDictationEnabled(dictationOn) }
        outcomes[.dictation] = dictationOn ? .on("On") : .off("Off")
    }

    // MARK: Alerts

    private func applyAlerts() async {
        if paceAlertsOn != env.paceAlertsEnabled() { env.setPaceAlertsEnabled(paceAlertsOn) }
        guard paceAlertsOn else {
            outcomes[.alerts] = .off("Off")
            return
        }
        // Asked now, while the person is looking, rather than when the first alert is due.
        if await env.notificationPermission() == .notAsked {
            await env.requestNotificationPermission()
        }
        let permission = await env.notificationPermission()
        notificationPermission = permission
        outcomes[.alerts] = permission == .denied
            ? .failed("On, but notifications are off for LobsterOne in System Settings")
            : .on("On")
    }

    func refreshNotificationPermission() async {
        notificationPermission = await env.notificationPermission()
    }

    // MARK: Screensaver

    private func applyScreensaver() {
        guard screensaverAvailable else {
            outcomes[.screensaver] = .skipped
            return
        }
        if screensaverStyle != env.screensaverStyle() { env.setScreensaverStyle(screensaverStyle) }
        if !env.screensaverInstalled() {
            do {
                try env.installScreensaver()
            } catch {
                problem = "Couldn't install it: \(error.localizedDescription)"
                return
            }
        }
        screensaverInstalled = env.screensaverInstalled()
        outcomes[.screensaver] = .on(screensaverStyle.title)
    }

    // MARK: Claude Code

    func refreshClaudeCodeMod() async {
        claudeCodeMod = await env.claudeCodeMod()
    }

    /// Adds the band, or turns it back on. Where Claude Code isn't here, or this build has no
    /// band, there's nothing to add and the screen just moves on.
    private func applyClaudeCode() async {
        if claudeCodeMod == nil { await refreshClaudeCodeMod() }
        switch claudeCodeMod {
        case .claudeMissing:
            outcomes[.claudeCode] = .off("Claude Code not found")
        case .notBundled, nil:
            outcomes[.claudeCode] = .skipped
        case .installed:
            outcomes[.claudeCode] = .on("Band added")
        case .notInstalled, .switchedOff:
            do {
                try await env.addClaudeCodeMod()
            } catch {
                problem = error.localizedDescription
                return
            }
            await refreshClaudeCodeMod()
            if case .installed = claudeCodeMod {
                outcomes[.claudeCode] = .on("Band added")
            } else {
                problem = "Claude Code didn't confirm the band was added. Try again, or skip and add it in Settings, Tools."
            }
        }
    }

    // MARK: AWS

    private func applyAWS() {
        wantsAWS = !awsConnected
        outcomes[.aws] = awsConnected ? .on("Connected") : .on("Settings opens on AWS next")
    }

    /// "Codex, Claude Code and Mistral Vibe".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
