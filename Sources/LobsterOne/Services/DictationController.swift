import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// What the controller needs from the speech engine. A protocol only so the state transitions
/// can be tested with a fake that decides when `start()` returns.
@MainActor
protocol DictationEngine: AnyObject {
    var languageName: String? { get }
    var modelState: DictationModelState { get }
    var onModelState: (DictationModelState) -> Void { get set }
    var onPartial: (String) -> Void { get set }
    var onLevel: (Float) -> Void { get set }
    func prepare() async
    func changeLanguage() async
    func start() async throws
    func finish() async -> String
    func cancel() async
}

extension DictationSpeechEngine: DictationEngine {}

/// What the controller needs from the dictation key.
@MainActor
protocol DictationKey: AnyObject {
    var onBegin: () -> Void { get set }
    var onCommit: () -> Void { get set }
    var onDiscard: () -> Void { get set }
    func start()
    func stop()
    /// Throws, keeping the old shortcut, when the new one is taken.
    func setShortcut(_ shortcut: DictationShortcut) throws
    /// No missed-release check for the hold under way: typing into the field would trip it.
    func pauseReleaseCheck()
}

extension DictationHotkey: DictationKey {}

/// What the controller needs from the type-as-you-speak streamer.
@MainActor
protocol DictationStreamer: AnyObject {
    func begin()
    func update(_ target: String)
    func finish(_ final: String) async -> TextStreamer.Outcome
    func undo() async
}

extension TextStreamer: DictationStreamer {}

/// Hold the shortcut, speak, release: ties the key, the speech engine and the paste together,
/// and publishes what the HUD and the Settings rows show.
///
/// Every call into the engine runs in order on one chain of tasks, so a quick press can't have
/// its cancel overtaken by its own start. A discard also cancels straight away, outside the
/// chain, so the microphone closes at once even while the first start is still loading the model.
@MainActor
final class DictationController: ObservableObject {
    static let enabledKey = "dictationEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    nonisolated static let streamingKey = "dictationStreaming"

    /// Type the words into the field while the person speaks, instead of pasting on release.
    static var streamsWhileSpeaking: Bool {
        get { UserDefaults.standard.object(forKey: streamingKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: streamingKey) }
    }

    enum State: Equatable { case idle, listening, transcribing, notice(String) }

    @Published private(set) var state: State = .idle
    /// Live text while listening. Cleared at the start of each recording.
    @Published private(set) var partial = ""
    @Published private(set) var level: Float = 0
    /// This recording is being typed into the field as it goes, so the HUD needn't show the words.
    @Published private(set) var isStreaming = false

    // For the Settings rows.
    @Published private(set) var isOn = DictationController.isEnabled
    @Published private(set) var typesWhileSpeaking = DictationController.streamsWhileSpeaking
    /// Nil until checked, which is quick but async.
    @Published private(set) var availability: DictationAvailability?
    @Published private(set) var modelState: DictationModelState = .unknown
    @Published private(set) var languageName: String?
    @Published private(set) var microphone: DictationPermissions.State = .notAsked
    @Published private(set) var accessibility = false
    /// The shortcut the key is listening for.
    @Published private(set) var shortcut = DictationShortcut.current

    /// The system calls the controller makes besides the engine and key, swappable for tests.
    struct System {
        var availability: () async -> DictationAvailability
        var microphone: @MainActor () -> DictationPermissions.State
        var requestMicrophone: @MainActor () async -> DictationPermissions.State
        var accessibility: @MainActor () -> Bool
        var promptAccessibility: @MainActor () -> Void
        var paste: @MainActor (String) async -> PasteOutcome
        var secureInput: @MainActor () -> Bool = { IsSecureEventInputEnabled() }
        /// An ordinary copy, left on the clipboard for good.
        var copy: @MainActor (String) -> Void = { TextPaster.writeCopy($0, to: .general) }

        static let live = System(
            availability: { await DictationSpeechEngine.availability() },
            microphone: { DictationPermissions.microphone },
            requestMicrophone: { await DictationPermissions.requestMicrophone() },
            accessibility: { DictationPermissions.accessibility },
            promptAccessibility: { DictationPermissions.promptAccessibility() },
            paste: { await TextPaster.paste($0) }
        )
    }

    nonisolated static let noticeDuration: Duration = .milliseconds(2500)
    /// Below this on the 0…1 meter for a whole recording, the microphone was silent, not quiet:
    /// even an empty room moves the meter more than this.
    nonisolated static let silenceLevel: Float = 0.02

    private let engine: DictationEngine
    private let key: DictationKey
    private let streamer: DictationStreamer
    private let system: System
    private let noticeDuration: Duration

    /// Bumped by every begin and discard, so a start queued behind older work knows whether
    /// it is still wanted by the time it runs.
    private var recording = 0
    /// The start of the current recording; nil error when it settled fine.
    private var starting: Task<Error?, Never>?
    /// The last engine call queued. Each new one waits for it.
    private var chain: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var listeningSince: Date?
    /// The loudest the meter got in this recording. Still zero at the end means the microphone
    /// gave nothing at all, which calls for a different message than unclear speech.
    private var peakLevel: Float = 0
    private var accessibilityWatch: Task<Void, Never>?
    /// Settings is recording a new shortcut, so the key stays off until it is done.
    private var keySuspended = false

    /// Nil parameters mean the real thing; tests pass fakes.
    init(engine: DictationEngine? = nil,
         key: DictationKey? = nil,
         streamer: DictationStreamer? = nil,
         system: System? = nil,
         noticeDuration: Duration = DictationController.noticeDuration) {
        self.engine = engine ?? DictationSpeechEngine()
        self.key = key ?? DictationHotkey()
        self.streamer = streamer ?? TextStreamer()
        self.system = system ?? .live
        self.noticeDuration = noticeDuration
    }

    /// Wires the key and engine and, if dictation was left on, arms it. Doesn't ask for any
    /// permission: a launch shouldn't pop dialogs.
    func start() {
        key.onBegin = { [weak self] in self?.begin() }
        key.onCommit = { [weak self] in self?.commit() }
        key.onDiscard = { [weak self] in self?.discard() }
        engine.onModelState = { [weak self] state in
            guard let self else { return }
            self.modelState = state
            self.languageName = self.engine.languageName
        }
        engine.onPartial = { [weak self] text in
            guard let self, self.isRecording else { return }
            self.partial = text
            if self.isStreaming { self.streamer.update(DictationText.clean(text)) }
        }
        engine.onLevel = { [weak self] level in
            guard let self else { return }
            // The engine reports 0 as it closes the mic; anything later than that is stale.
            self.level = self.state == .listening ? level : 0
            if self.state == .listening { self.peakLevel = max(self.peakLevel, level) }
        }
        applySavedShortcut()
        refreshPermissions()
        Task { await arm(asking: false) }
    }

    /// The saved combination may have been taken by another app since it was chosen. Then this
    /// launch uses Right Option, and the saved choice is kept for the next.
    private func applySavedShortcut() {
        do {
            try key.setShortcut(shortcut)
        } catch {
            DebugLog.shared.log("Dictation: saved shortcut \(shortcut.displayName) unavailable (\(error)), using the default")
            try? key.setShortcut(.defaultValue)
            shortcut = .defaultValue
        }
    }

    /// From Settings. Nil when the shortcut changed; otherwise a short reason to show, and the
    /// old shortcut stays. Only a shortcut that worked is saved.
    func setShortcut(_ new: DictationShortcut) -> String? {
        if let problem = DictationShortcut.problem(with: new) { return problem }
        guard new != shortcut else { return nil }
        do {
            try key.setShortcut(new)
        } catch DictationHotkey.ShortcutError.taken(let reason) {
            return reason
        } catch {
            return "That shortcut can't be used."
        }
        shortcut = new
        DictationShortcut.current = new
        DebugLog.shared.log("Dictation: shortcut set to \(new.displayName)")
        return nil
    }

    /// While Settings records a shortcut: pressing the current one there mustn't dictate, and a
    /// combination has to reach Settings rather than be swallowed by the hotkey.
    func suspendKey() {
        guard !keySuspended else { return }
        keySuspended = true
        key.stop()
    }

    func resumeKey() {
        guard keySuspended else { return }
        keySuspended = false
        guard Self.isEnabled, availability == .available else { return }
        key.start()
    }

    /// The Settings toggle. Turning it on asks for the microphone, then Accessibility.
    func setEnabled(_ on: Bool) {
        Self.isEnabled = on
        isOn = on
        DebugLog.shared.log("Dictation: turned \(on ? "on" : "off")")
        if on {
            Task { await arm(asking: true) }
        } else {
            key.stop()
            accessibilityWatch?.cancel()
        }
    }

    /// The Settings toggle for typing while speaking. Takes effect from the next recording.
    func setStreaming(_ on: Bool) {
        Self.streamsWhileSpeaking = on
        typesWhileSpeaking = on
        DebugLog.shared.log("Dictation: typing while speaking turned \(on ? "on" : "off")")
    }

    /// The Settings language menu; nil follows the system language. Switches after any
    /// recording under way, downloading the new language's model if this Mac lacks it.
    func setLanguage(_ identifier: String?) {
        guard identifier != DictationLanguage.selectedIdentifier else { return }
        DictationLanguage.selectedIdentifier = identifier
        DebugLog.shared.log("Dictation: language set to \(identifier ?? "the system language")")
        // Off or not yet armed: the next `prepare()` reads the new choice.
        guard Self.isEnabled, availability == .available else { return }
        let previous = chain
        chain = Task {
            await previous?.value
            await self.engine.changeLanguage()
            self.modelState = self.engine.modelState
            self.languageName = self.engine.languageName
        }
    }

    func requestMicrophone() {
        Task {
            _ = await system.requestMicrophone()
            refreshPermissions()
        }
    }

    func refreshPermissions() {
        microphone = system.microphone()
        accessibility = system.accessibility()
    }

    private func arm(asking: Bool) async {
        if availability == nil { availability = await system.availability() }
        guard Self.isEnabled else { return }
        guard availability == .available else {
            DebugLog.shared.log("Dictation: on but not available here (\(String(describing: availability)))")
            return
        }
        if !keySuspended { key.start() }
        if asking {
            _ = await system.requestMicrophone()
            if !system.accessibility() { system.promptAccessibility() }
        }
        refreshPermissions()
        watchForAccessibility()
        await engine.prepare()
        modelState = engine.modelState
        languageName = engine.languageName
    }

    /// Key monitors installed before Accessibility was granted hear nothing from other apps,
    /// and the grant happens in System Settings where nothing tells us. So while it is missing,
    /// look every two seconds and put the monitors in again once it arrives.
    private func watchForAccessibility() {
        accessibilityWatch?.cancel()
        guard !system.accessibility() else { return }
        accessibilityWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, Self.isEnabled else { return }
                if self.system.accessibility() {
                    DebugLog.shared.log("Dictation: Accessibility granted, re-arming the key")
                    if !self.keySuspended {
                        self.key.stop()
                        self.key.start()
                    }
                    self.refreshPermissions()
                    return
                }
            }
        }
    }

    private var isRecording: Bool { state == .listening || state == .transcribing }

    // MARK: Key events

    func begin() {
        // One recording at a time; a press while the last one is still being turned into
        // text is ignored.
        guard !isRecording else { return }
        refreshPermissions()
        switch microphone {
        case .allowed:
            break
        case .notAsked:
            // This press only asks. Recording while the prompt is up would capture nothing.
            DebugLog.shared.log("Dictation: asking for the microphone")
            requestMicrophone()
            return
        case .denied:
            showNotice("Microphone is off. Turn it on in System Settings.")
            return
        }

        // A first download can take minutes; holding the mic open and the HUD up that long
        // would look stuck.
        switch modelState {
        case .downloading, .notInstalled:
            showNotice("The speech model is still downloading.")
            return
        default:
            break
        }

        noticeTimer?.cancel()
        recording += 1
        let id = recording
        partial = ""
        level = 0
        peakLevel = 0
        state = .listening
        listeningSince = Date()
        // Typing needs Accessibility, and Secure Input drops synthetic keys silently. Short of
        // either, this recording pastes on release as usual.
        let streams = Self.streamsWhileSpeaking && accessibility && !system.secureInput()
        isStreaming = streams
        if streams { key.pauseReleaseCheck() }
        DebugLog.shared.log(streams ? "Dictation: listening, typing as it goes" : "Dictation: listening")

        let previous = chain
        let start = Task { () -> Error? in
            await previous?.value
            // Discarded before it got its turn: never open the mic.
            guard id == self.recording else { return nil }
            // Before the mic opens, so the first words have somewhere to go. The app in front
            // now is the one the person means to dictate into.
            if streams { self.streamer.begin() }
            do {
                try await self.engine.start()
                return nil
            } catch {
                // Still holding the key: say so now rather than on release.
                if id == self.recording, self.state == .listening {
                    self.recording += 1
                    self.failed(error)
                }
                return error
            }
        }
        starting = start
        chain = Task { _ = await start.value }
    }

    func commit() {
        guard state == .listening else { return }
        let id = recording
        let heardNothing = peakLevel < Self.silenceLevel
        let streams = isStreaming
        state = .transcribing
        level = 0
        if let listeningSince {
            DebugLog.shared.log(String(format: "Dictation: released after %.1fs", Date().timeIntervalSince(listeningSince)))
        }
        let start = starting
        let previous = chain
        chain = Task {
            await previous?.value
            if let error = await start?.value {
                failed(error)
                return
            }
            let text = await engine.finish()
            guard id == recording else { return }
            if text.isEmpty {
                // A guess typed while speaking that the model then dropped.
                if streams { await streamer.undo() }
                if heardNothing {
                    DebugLog.shared.log("Dictation: the microphone was silent for the whole recording")
                    showNotice("No sound from the microphone. Pick another in Settings.")
                } else {
                    showNotice("Didn't catch that.")
                }
                return
            }
            if streams {
                await finishStreaming(text)
                return
            }
            switch await system.paste(text) {
            case .pasted:
                DebugLog.shared.log("Dictation: pasted \(text.count) characters")
                finishRecording()
            case .copied(let reason):
                DebugLog.shared.log("Dictation: couldn't paste (\(reason)), left \(text.count) characters on the clipboard")
                showNotice(Self.copiedNotice(accessibilityMissing: reason == .noAccessibility,
                                             secureInput: reason == .secureInput))
            }
        }
    }

    func discard() {
        guard state == .listening else { return }
        recording += 1
        DebugLog.shared.log("Dictation: discarded")
        let streams = isStreaming
        finishRecording()
        // Takes back what was typed, straight away. If this recording's start hasn't begun the
        // streamer yet, it never will (the recording is stale), and the undo finds nothing open.
        // The next start waits for it, so it can't land on the next recording's text.
        let undo: Task<Void, Never>? = streams ? Task { await self.streamer.undo() } : nil
        // Straight away, so the mic closes even while a start is still waiting on the model;
        // then again in turn, for a start that opened it after this ran.
        let now = Task { await engine.cancel() }
        let previous = chain
        chain = Task {
            await now.value
            await undo?.value
            await previous?.value
            await engine.cancel()
        }
    }

    /// Waits until every queued engine call has run. For tests.
    func settle() async {
        while let current = chain {
            await current.value
            if chain == current { return }
        }
    }

    // MARK: Outcomes

    /// The words are already in the field; this types the last correction. If the person moved
    /// to another app first, typing stopped there and the whole text goes on the clipboard.
    private func finishStreaming(_ text: String) async {
        switch await streamer.finish(text) {
        case .typed:
            finishRecording()
        case .interrupted(_, let reason):
            system.copy(text)
            DebugLog.shared.log("Dictation: typing stopped (\(reason)), left \(text.count) characters on the clipboard")
            showNotice(reason == .focusMoved
                       ? "Focus moved. Copied, press ⌘V to paste."
                       : Self.copiedNotice(accessibilityMissing: reason == .noAccessibility,
                                           secureInput: reason == .secureInput))
        }
    }

    /// Why dictation can't be switched on here, for Settings; nil when it can. Says what
    /// dictation is as well as what it needs, since someone on an older macOS has never seen
    /// it work and a bare "Needs macOS 26" gives them no reason to update.
    nonisolated static func unavailableExplanation(_ availability: DictationAvailability?,
                                                   osVersion: OperatingSystemVersion) -> String? {
        let what = "Hold a shortcut, speak, and the text lands where your cursor is."
        switch availability {
        case .available, nil:
            return nil
        case .needsMacOS26:
            let running = osVersion.minorVersion == 0
                ? "\(osVersion.majorVersion)" : "\(osVersion.majorVersion).\(osVersion.minorVersion)"
            return "\(what) It uses Apple's on-device speech model, which needs macOS 26 or later. This Mac runs macOS \(running), so update macOS to use it."
        case .unsupportedMac:
            return "\(what) It uses Apple's on-device speech model, which needs a Mac with Apple silicon."
        case .unsupportedLanguage:
            return "\(what) Apple's on-device speech model doesn't support this Mac's language yet."
        }
    }

    /// What the pill says when the text went to the clipboard instead of the field. It names
    /// the cause when there is one the person can act on: "press ⌘V" alone left them wondering
    /// why dictation had stopped typing.
    nonisolated static func copiedNotice(accessibilityMissing: Bool, secureInput: Bool) -> String {
        if accessibilityMissing { return "Accessibility is off, so it's copied. Press ⌘V to paste." }
        if secureInput { return "This field blocks typing, so it's copied. Press ⌘V." }
        return "Copied. Press ⌘V to paste."
    }

    private func finishRecording() {
        state = .idle
        partial = ""
        level = 0
        isStreaming = false
        listeningSince = nil
    }

    private func failed(_ error: Error) {
        DebugLog.shared.log("Dictation: couldn't start (\(error))")
        switch error {
        case DictationAudioCapture.CaptureError.noInput:
            showNotice("No microphone found.")
        case DictationAudioCapture.CaptureError.timedOut:
            showNotice("The microphone didn't respond.")
        default:
            if case .downloading = modelState {
                showNotice("The speech model is still downloading.")
            } else {
                showNotice("Dictation isn't ready yet.")
            }
        }
    }

    private func showNotice(_ text: String) {
        partial = ""
        level = 0
        isStreaming = false
        listeningSince = nil
        state = .notice(text)
        noticeTimer?.cancel()
        noticeTimer = Task {
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, case .notice = state else { return }
            state = .idle
        }
    }
}
