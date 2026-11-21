import Foundation
import Testing
@testable import LobsterOne

/// An engine whose `start()` can be held open, to play out a quick press or a chord arriving
/// while the start is still getting ready. Mirrors the real engine: the mic opens as soon as
/// `start()` is called and `cancel()` closes it without waiting for the start.
@MainActor
private final class FakeEngine: DictationEngine {
    var languageName: String? = "English (Australia)"
    var modelState: DictationModelState = .ready
    var onModelState: (DictationModelState) -> Void = { _ in }
    var onPartial: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    var holdStart = false
    var startError: Error?
    var text = "hello there"
    private(set) var micOpen = false
    private(set) var events: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    var isHeld: Bool { gate != nil }

    func prepare() async { events.append("prepare") }
    func changeLanguage() async { events.append("changeLanguage") }

    func start() async throws {
        events.append("start")
        micOpen = true
        if holdStart { await withCheckedContinuation { gate = $0 } }
        events.append("started")
        if let startError {
            micOpen = false
            throw startError
        }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func finish() async -> String {
        events.append("finish")
        micOpen = false
        return text
    }

    func cancel() async {
        events.append("cancel")
        micOpen = false
    }
}

@MainActor
private final class FakeKey: DictationKey {
    var onBegin: () -> Void = {}
    var onCommit: () -> Void = {}
    var onDiscard: () -> Void = {}
    private(set) var running = false
    private(set) var shortcut = DictationShortcut.defaultValue
    /// Shortcuts another app holds; setting one throws as the real key does.
    var taken: [DictationShortcut] = []
    func start() { running = true }
    func stop() {
        running = false
        onDiscard()
    }
    private(set) var releaseCheckPauses = 0
    func pauseReleaseCheck() { releaseCheckPauses += 1 }
    func setShortcut(_ new: DictationShortcut) throws {
        if taken.contains(new) { throw DictationHotkey.ShortcutError.taken("Another app already uses that shortcut.") }
        shortcut = new
    }
}

/// Records what the controller asks of the streamer. Types nothing.
@MainActor
private final class FakeStreamer: DictationStreamer {
    private(set) var events: [String] = []
    var outcome: TextStreamer.Outcome = .typed

    func begin() { events.append("begin") }
    func update(_ target: String) { events.append("update \(target)") }
    func finish(_ final: String) async -> TextStreamer.Outcome {
        events.append("finish \(final)")
        return outcome
    }
    func undo() async { events.append("undo") }
}

@MainActor
private final class Harness {
    let engine = FakeEngine()
    let key = FakeKey()
    let streamer = FakeStreamer()
    var microphone: DictationPermissions.State = .allowed
    var micRequests = 0
    var pasted: [String] = []
    var copied: [String] = []
    var outcome: PasteOutcome = .pasted
    var secureInput = false
    private(set) var controller: DictationController!

    /// The controller is made and started straight away, so the key's callbacks are wired
    /// before a test presses anything. `enabled` is what `isEnabled` holds at launch.
    private let savedEnabled = UserDefaults.standard.object(forKey: DictationController.enabledKey)
    private let savedShortcut = UserDefaults.standard.object(forKey: DictationShortcut.defaultsKey)
    private let savedStreaming = UserDefaults.standard.object(forKey: DictationController.streamingKey)

    /// `shortcut` is what was saved before launch; `taken` what the key will refuse;
    /// `streaming` whether typing while speaking is on.
    init(enabled: Bool = false, shortcut: DictationShortcut = .defaultValue, taken: [DictationShortcut] = [],
         streaming: Bool = false) {
        DictationController.isEnabled = enabled
        DictationController.streamsWhileSpeaking = streaming
        DictationShortcut.current = shortcut
        key.taken = taken
        let system = DictationController.System(
            availability: { .available },
            microphone: { [weak self] in self?.microphone ?? .allowed },
            requestMicrophone: { [weak self] in
                self?.micRequests += 1
                return self?.microphone ?? .allowed
            },
            accessibility: { true },
            promptAccessibility: {},
            paste: { [weak self] text in
                self?.pasted.append(text)
                return self?.outcome ?? .pasted
            },
            secureInput: { [weak self] in self?.secureInput ?? false },
            copy: { [weak self] text in self?.copied.append(text) }
        )
        controller = DictationController(engine: engine, key: key, streamer: streamer, system: system,
                                         noticeDuration: .seconds(60))
        controller.start()
    }

    deinit {
        UserDefaults.standard.set(savedEnabled, forKey: DictationController.enabledKey)
        UserDefaults.standard.set(savedShortcut, forKey: DictationShortcut.defaultsKey)
        UserDefaults.standard.set(savedStreaming, forKey: DictationController.streamingKey)
    }

    /// Lets queued tasks run until the fake start is parked at its gate.
    func waitUntilStartIsHeld() async {
        for _ in 0..<1000 where !engine.isHeld { await Task.yield() }
    }

    /// Lets queued tasks run a while; for things with no handle to await.
    func spin() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

/// One at a time: the on/off setting lives in UserDefaults, which the harness sets.
@MainActor @Suite(.serialized)
struct DictationControllerTests {
    @Test func dictationHoldThenReleasePastesAndHides() async {
        let h = Harness()
        h.key.onBegin()
        #expect(h.controller.state == .listening)
        h.key.onCommit()
        #expect(h.controller.state == .transcribing)
        await h.controller.settle()
        #expect(h.pasted == ["hello there"])
        #expect(h.controller.state == .idle)
        #expect(h.engine.events == ["start", "started", "finish"])
    }

    @Test func dictationNothingHeardSaysSo() async {
        let h = Harness()
        h.engine.text = ""
        h.key.onBegin()
        h.engine.onLevel(0.4)
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.pasted.isEmpty)
        #expect(h.controller.state == .notice("Didn't catch that."))
    }

    @Test func dictationSilentMicrophonePointsAtSettings() async {
        let h = Harness()
        h.engine.text = ""
        h.key.onBegin()
        h.engine.onLevel(0)
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.controller.state == .notice("No sound from the microphone. Pick another in Settings."))
    }

    @Test func dictationCopiedInsteadOfPastedSaysHowToPaste() async {
        let h = Harness()
        h.outcome = .copied(reason: .postFailed)
        h.key.onBegin()
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.controller.state == .notice("Copied. Press ⌘V to paste."))
    }

    @Test func dictationUnavailableExplainsWhatItIsAndWhatItNeeds() {
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
        let old = DictationController.unavailableExplanation(.needsMacOS26, osVersion: sequoia)
        #expect(old == "Hold a shortcut, speak, and the text lands where your cursor is. It uses Apple's on-device speech model, which needs macOS 26 or later. This Mac runs macOS 15.6, so update macOS to use it.")
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        #expect(DictationController.unavailableExplanation(.needsMacOS26, osVersion: sonoma)?.contains("runs macOS 14,") == true)
        #expect(DictationController.unavailableExplanation(.unsupportedMac, osVersion: sequoia)?.contains("Apple silicon") == true)
        #expect(DictationController.unavailableExplanation(.unsupportedLanguage, osVersion: sequoia)?.contains("language") == true)
        #expect(DictationController.unavailableExplanation(.available, osVersion: sequoia) == nil)
        #expect(DictationController.unavailableExplanation(nil, osVersion: sequoia) == nil)
    }

    @Test func dictationCopiedForWantOfAccessibilitySaysSo() async {
        let h = Harness()
        h.outcome = .copied(reason: .noAccessibility)
        h.key.onBegin()
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.controller.state == .notice("Accessibility is off, so it's copied. Press ⌘V to paste."))
    }

    @Test func dictationCopiedInASecureFieldSaysSo() async {
        let h = Harness()
        h.outcome = .copied(reason: .secureInput)
        h.key.onBegin()
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.controller.state == .notice("This field blocks typing, so it's copied. Press ⌘V."))
    }

    @Test func dictationNoticeClearsItselfAfterItsTime() async throws {
        let h = Harness()
        let controller = DictationController(
            engine: h.engine, key: h.key,
            system: .init(availability: { .available }, microphone: { .denied }, requestMicrophone: { .denied },
                          accessibility: { true }, promptAccessibility: {}, paste: { _ in .pasted }),
            noticeDuration: .milliseconds(20))
        controller.start()
        h.key.onBegin()
        #expect(controller.state != .idle)
        for _ in 0..<200 where controller.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.state == .idle)
    }

    @Test func dictationCommitBeforeStartReturnsWaitsForIt() async {
        let h = Harness()
        h.engine.holdStart = true
        h.key.onBegin()
        await h.waitUntilStartIsHeld()
        h.key.onCommit()
        await h.spin()
        #expect(!h.engine.events.contains("finish"))
        #expect(h.controller.state == .transcribing)
        h.engine.release()
        await h.controller.settle()
        #expect(h.engine.events == ["start", "started", "finish"])
        #expect(h.pasted == ["hello there"])
        #expect(h.controller.state == .idle)
    }

    @Test func dictationDiscardWhileStartingClosesTheMicAtOnce() async {
        let h = Harness()
        h.engine.holdStart = true
        h.key.onBegin()
        await h.waitUntilStartIsHeld()
        #expect(h.engine.micOpen)
        h.key.onDiscard()
        #expect(h.controller.state == .idle)
        await h.spin()
        // Closed while the start is still stuck, not only once it returns.
        #expect(!h.engine.micOpen)
        h.engine.release()
        await h.controller.settle()
        #expect(!h.engine.micOpen)
        #expect(h.pasted.isEmpty)
        #expect(h.controller.state == .idle)
    }

    @Test func dictationDiscardBeforeStartRunsNeverOpensTheMic() async {
        let h = Harness()
        h.key.onBegin()
        h.key.onDiscard()
        await h.controller.settle()
        #expect(!h.engine.events.contains("start"))
        #expect(!h.engine.micOpen)
        #expect(h.controller.state == .idle)
    }

    @Test func dictationQuickPressesInARowEndWithTheLastOne() async {
        let h = Harness()
        h.engine.holdStart = true
        h.key.onBegin()
        await h.waitUntilStartIsHeld()
        h.key.onDiscard()
        h.key.onBegin()          // a new press while the first start is still stuck
        h.engine.release()
        await h.waitUntilStartIsHeld()
        #expect(h.engine.micOpen)
        h.key.onCommit()
        h.engine.release()
        await h.controller.settle()
        #expect(h.pasted == ["hello there"])
        #expect(!h.engine.micOpen)
        #expect(h.controller.state == .idle)
    }

    @Test func dictationStartFailureShowsANoticeAndIgnoresTheRelease() async {
        let h = Harness()
        h.engine.startError = DictationAudioCapture.CaptureError.noInput
        h.key.onBegin()
        await h.controller.settle()
        #expect(h.controller.state == .notice("No microphone found."))
        h.key.onCommit()
        await h.controller.settle()
        #expect(!h.engine.events.contains("finish"))
        #expect(h.pasted.isEmpty)
    }

    @Test func dictationMicrophoneTimeoutSaysSo() async {
        let h = Harness()
        h.engine.startError = DictationAudioCapture.CaptureError.timedOut
        h.key.onBegin()
        await h.controller.settle()
        #expect(h.controller.state == .notice("The microphone didn't respond."))
    }

    @Test func dictationStartFailureAfterReleaseShowsANotice() async {
        let h = Harness()
        h.engine.holdStart = true
        h.engine.startError = DictationSpeechEngine.EngineError.unavailable
        h.key.onBegin()
        await h.waitUntilStartIsHeld()
        h.key.onCommit()
        h.engine.release()
        await h.controller.settle()
        #expect(h.controller.state == .notice("Dictation isn't ready yet."))
        #expect(!h.engine.events.contains("finish"))
        #expect(h.pasted.isEmpty)
    }

    @Test func dictationPressWhileTranscribingIsIgnored() async {
        let h = Harness()
        h.key.onBegin()
        h.key.onCommit()
        h.key.onBegin()
        #expect(h.controller.state == .transcribing)
        await h.controller.settle()
        #expect(h.engine.events == ["start", "started", "finish"])
    }

    @Test func dictationMicrophoneNotAskedAsksAndDoesNotRecord() async {
        let h = Harness()
        h.microphone = .notAsked
        h.key.onBegin()
        await h.spin()
        #expect(h.micRequests == 1)
        #expect(h.controller.state == .idle)
        #expect(!h.engine.events.contains("start"))
    }

    @Test func dictationMicrophoneDeniedPointsAtSettings() async {
        let h = Harness()
        h.microphone = .denied
        h.key.onBegin()
        await h.spin()
        #expect(h.micRequests == 0)
        #expect(h.controller.state == .notice("Microphone is off. Turn it on in System Settings."))
        #expect(!h.engine.events.contains("start"))
    }

    @Test func dictationPressWhileTheModelDownloadsSaysSoAndDoesNotRecord() async {
        let h = Harness()
        h.engine.onModelState(.downloading(0.4))
        h.key.onBegin()
        #expect(h.controller.state == .notice("The speech model is still downloading."))
        await h.controller.settle()
        #expect(!h.engine.events.contains("start"))
    }

    @Test func dictationLatePartialsAfterADiscardAreDropped() async {
        let h = Harness()
        h.key.onBegin()
        h.engine.onPartial("hello")
        #expect(h.controller.partial == "hello")
        h.key.onDiscard()
        h.engine.onPartial("hello again")
        h.engine.onLevel(0.8)
        #expect(h.controller.partial == "")
        #expect(h.controller.level == 0)
        await h.controller.settle()
    }

    @Test func dictationTurningOnArmsTheKeyAndPreparesTheModel() async {
        let h = Harness(enabled: false)
        await h.spin()
        #expect(!h.key.running)
        h.controller.setEnabled(true)
        await h.spin()
        #expect(h.key.running)
        #expect(h.micRequests == 1)
        #expect(h.engine.events.contains("prepare"))
        h.controller.setEnabled(false)
        #expect(!h.key.running)
    }

    // MARK: Typing while speaking

    @Test func dictationStreamingForwardsCleanedPartialsAndFinishesWithoutPasting() async {
        let h = Harness(streaming: true)
        h.key.onBegin()
        #expect(h.controller.isStreaming)
        await h.controller.settle()
        h.engine.onPartial(" hello  there\n")
        h.engine.onPartial(" hello there friend ")
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.streamer.events == ["begin", "update hello there", "update hello there friend", "finish hello there"])
        #expect(h.pasted.isEmpty)
        #expect(h.copied.isEmpty)
        #expect(h.controller.state == .idle)
        #expect(!h.controller.isStreaming)
    }

    @Test func dictationStreamingPausesTheMissedReleaseCheck() async {
        let typing = Harness(streaming: true)
        typing.key.onBegin()
        #expect(typing.key.releaseCheckPauses == 1)
        typing.key.onDiscard()
        await typing.controller.settle()

        let pasting = Harness()
        pasting.key.onBegin()
        #expect(pasting.key.releaseCheckPauses == 0)
        pasting.key.onDiscard()
        await pasting.controller.settle()
    }

    @Test func dictationStreamingDiscardUndoesWhatWasTyped() async {
        let h = Harness(streaming: true)
        h.key.onBegin()
        await h.controller.settle()
        h.engine.onPartial("hello")
        h.key.onDiscard()
        await h.controller.settle()
        #expect(h.streamer.events == ["begin", "update hello", "undo"])
        #expect(h.engine.events.contains("cancel"))
        #expect(h.pasted.isEmpty)
        #expect(h.controller.state == .idle)
    }

    @Test func dictationStreamingPartialAfterDiscardIsNotForwarded() async {
        let h = Harness(streaming: true)
        h.key.onBegin()
        await h.controller.settle()
        h.key.onDiscard()
        h.engine.onPartial("hello again")
        await h.controller.settle()
        h.engine.onPartial("and again")
        #expect(!h.streamer.events.contains { $0.hasPrefix("update") })
    }

    @Test func dictationStreamingDiscardBeforeTheStartRanNeverBeginsTheStreamer() async {
        let h = Harness(streaming: true)
        h.key.onBegin()
        h.key.onDiscard()
        await h.controller.settle()
        #expect(!h.streamer.events.contains("begin"))
    }

    @Test func dictationStreamingInterruptedCopiesTheTextAndSaysSo() async {
        let h = Harness(streaming: true)
        h.streamer.outcome = .interrupted(typedSoFar: "hello", reason: .focusMoved)
        h.key.onBegin()
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.copied == ["hello there"])
        #expect(h.pasted.isEmpty)
        #expect(h.controller.state == .notice("Focus moved. Copied, press ⌘V to paste."))
    }

    @Test func dictationStreamingStoppedBySecureInputMidwayCopiesTheText() async {
        let h = Harness(streaming: true)
        h.streamer.outcome = .interrupted(typedSoFar: "", reason: .secureInput)
        h.key.onBegin()
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.copied == ["hello there"])
        #expect(h.controller.state == .notice("This field blocks typing, so it's copied. Press ⌘V."))
    }

    @Test func dictationStreamingNothingHeardUndoesTheGuess() async {
        let h = Harness(streaming: true)
        h.engine.text = ""
        h.key.onBegin()
        await h.controller.settle()
        h.engine.onLevel(0.4)
        h.engine.onPartial("um")
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.streamer.events == ["begin", "update um", "undo"])
        #expect(h.pasted.isEmpty)
        #expect(h.controller.state == .notice("Didn't catch that."))
    }

    @Test func dictationStreamingUnderSecureInputPastesInstead() async {
        let h = Harness(streaming: true)
        h.secureInput = true
        h.key.onBegin()
        #expect(!h.controller.isStreaming)
        h.engine.onPartial("hello")
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.streamer.events.isEmpty)
        #expect(h.pasted == ["hello there"])
    }

    @Test func dictationStreamingOffPastesAsBefore() async {
        let h = Harness(streaming: false)
        h.key.onBegin()
        h.engine.onPartial("hello")
        h.key.onCommit()
        await h.controller.settle()
        #expect(h.streamer.events.isEmpty)
        #expect(h.pasted == ["hello there"])
        #expect(h.controller.state == .idle)
    }

    @Test func dictationStreamingSettingIsSavedAndMirrored() {
        let h = Harness(streaming: false)
        #expect(!h.controller.typesWhileSpeaking)
        h.controller.setStreaming(true)
        #expect(h.controller.typesWhileSpeaking)
        #expect(DictationController.streamsWhileSpeaking)
        UserDefaults.standard.removeObject(forKey: DictationController.streamingKey)
        #expect(!DictationController.streamsWhileSpeaking)
    }

    // MARK: Shortcut

    private static let controlOptionSpace = DictationShortcut.combo(keyCode: 49, modifiers: [.control, .option])

    @Test func dictationShortcutChangeReachesTheKeyAndIsSaved() {
        let h = Harness()
        #expect(h.controller.shortcut == .modifier(.rightOption))
        #expect(h.controller.setShortcut(Self.controlOptionSpace) == nil)
        #expect(h.controller.shortcut == Self.controlOptionSpace)
        #expect(h.key.shortcut == Self.controlOptionSpace)
        #expect(DictationShortcut.current == Self.controlOptionSpace)
        #expect(h.controller.setShortcut(.modifier(.fn)) == nil)
        #expect(DictationShortcut.current == .modifier(.fn))
    }

    @Test func dictationTakenShortcutIsRefusedAndNotSaved() {
        let h = Harness(taken: [Self.controlOptionSpace])
        #expect(h.controller.setShortcut(Self.controlOptionSpace) == "Another app already uses that shortcut.")
        #expect(h.controller.shortcut == .modifier(.rightOption))
        #expect(h.key.shortcut == .modifier(.rightOption))
        #expect(DictationShortcut.current == .modifier(.rightOption))
    }

    @Test func dictationInvalidShortcutNeverReachesTheKey() {
        let h = Harness()
        let plainA = DictationShortcut.combo(keyCode: 0, modifiers: [])
        #expect(h.controller.setShortcut(plainA) == "Add a modifier such as \u{2303} or \u{2325}.")
        #expect(h.key.shortcut == .modifier(.rightOption))
        #expect(DictationShortcut.current == .modifier(.rightOption))
    }

    @Test func dictationSavedShortcutIsUsedAtLaunch() {
        let h = Harness(shortcut: Self.controlOptionSpace)
        #expect(h.controller.shortcut == Self.controlOptionSpace)
        #expect(h.key.shortcut == Self.controlOptionSpace)
    }

    @Test func dictationSavedShortcutTakenAtLaunchFallsBackButStaysSaved() {
        let h = Harness(shortcut: Self.controlOptionSpace, taken: [Self.controlOptionSpace])
        #expect(h.controller.shortcut == .modifier(.rightOption))
        #expect(h.key.shortcut == .modifier(.rightOption))
        #expect(DictationShortcut.current == Self.controlOptionSpace)
    }

    /// Here rather than with the other shortcut tests because it writes the saved value, which
    /// these serialized tests also use. The harness puts it back afterwards.
    @Test func dictationSavedShortcutReadsBackAndSurvivesBadData() {
        withExtendedLifetime(Harness()) {
            UserDefaults.standard.removeObject(forKey: DictationShortcut.defaultsKey)
            #expect(DictationShortcut.current == .modifier(.rightOption))
            DictationShortcut.current = Self.controlOptionSpace
            #expect(DictationShortcut.current == Self.controlOptionSpace)
            UserDefaults.standard.set(Data([0xFF]), forKey: DictationShortcut.defaultsKey)
            #expect(DictationShortcut.current == .modifier(.rightOption))
        }
    }

    @Test func dictationKeyStaysOffWhileSettingsRecordsAShortcut() async {
        let h = Harness(enabled: true)
        await h.spin()
        #expect(h.key.running)
        h.controller.suspendKey()
        #expect(!h.key.running)
        h.controller.resumeKey()
        #expect(h.key.running)
    }

    @Test func dictationResumeLeavesTheKeyOffWhenDictationIsOff() async {
        let h = Harness(enabled: true)
        await h.spin()
        h.controller.suspendKey()
        h.controller.setEnabled(false)
        h.controller.resumeKey()
        #expect(!h.key.running)
    }
}

@Test func dictationHUDShowsShortTextWhole() {
    #expect(DictationHUD.tail(of: "fix the failing test") == "fix the failing test")
    #expect(DictationHUD.tail(of: "") == "")
}

@Test func dictationHUDShowsTheEndOfLongTextFromAWord() {
    let words = (1...40).map { "word\($0)" }.joined(separator: " ")
    let tail = DictationHUD.tail(of: words)
    #expect(tail.hasPrefix("\u{2026}word"))
    #expect(tail.hasSuffix("word40"))
    #expect(tail.count <= DictationHUD.tailLength + 1)
    // Starts on a whole word: the character before it in the original is a space.
    let shown = tail.dropFirst()
    let start = words.range(of: shown)!.lowerBound
    #expect(words[words.index(before: start)] == " ")
}

@Test func dictationHUDKeepsACutWordWhenThereIsNoSpaceNearby() {
    let long = String(repeating: "a", count: 200)
    let tail = DictationHUD.tail(of: long, limit: 10)
    #expect(tail == "\u{2026}" + String(repeating: "a", count: 10))
}
