import AVFoundation
import Foundation
#if compiler(>=6.2)
import Speech
#endif

/// Whether this Mac and this build can dictate at all.
nonisolated enum DictationAvailability: Equatable {
    case available
    case needsMacOS26          // older macOS, or built with an older SDK
    case unsupportedMac        // SpeechTranscriber.isAvailable == false (Intel)
    case unsupportedLanguage   // no supported locale near the chosen language and en-US missing
}

/// Where the on-device speech model stands, for the Settings row.
nonisolated enum DictationModelState: Equatable { case unknown, notInstalled, downloading(Double), ready, failed(String) }

/// Speech to text with Apple's on-device model. What the dictation controller talks to.
///
/// One recording at a time: `start()`, then `finish()` or `cancel()`. The microphone opens the
/// moment `start()` is called and the transcriber attaches when it is ready, so a person who
/// starts speaking straight away is not clipped. `finish()` and `cancel()` may be called while
/// `start()` is still getting ready (a quick press).
///
/// Built by an older Swift, or run before macOS 26, every call is a no-op and `availability()`
/// says `.needsMacOS26`. Transcript text is never logged.
@MainActor
final class DictationSpeechEngine {
    enum EngineError: Error {
        /// The model or language isn't ready, or this Mac can't run it. See `availability()`.
        case unavailable
    }

    /// The locale that will be used, e.g. "English (Australia)"; nil when unavailable.
    private(set) var languageName: String?
    private(set) var modelState: DictationModelState = .unknown {
        didSet { if modelState != oldValue { onModelState(modelState) } }
    }
    var onModelState: (DictationModelState) -> Void = { _ in }
    var onPartial: (String) -> Void = { _ in }     // live text (finals so far + current volatile), main actor
    var onLevel: (Float) -> Void = { _ in }        // 0…1, main actor

    /// Cached by `prepare()`: resolving them takes long enough to feel on a key press.
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var preparing: Task<Void, Never>?

    private var capture: DictationAudioCapture?
    private var attaching: Task<Void, Error>?
    /// Bumped by `cancel()`, so a start still getting ready knows to stand down.
    private var generation = 0
    #if compiler(>=6.2)
    /// `DictationTranscriptionSession`, typed loosely because the type only exists on macOS 26.
    private var session: AnyObject?
    #endif

    init() {}

    static func availability() async -> DictationAvailability {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard SpeechTranscriber.isAvailable else { return .unsupportedMac }
            guard await DictationSpeechSupport.resolveLocale() != nil else { return .unsupportedLanguage }
            return .available
        }
        #endif
        return .needsMacOS26
    }

    /// Resolves the locale, downloads the model if needed, warms it up. Safe to call repeatedly.
    func prepare() async {
        if format != nil, modelState == .ready { return }
        if let preparing {
            await preparing.value
            return
        }
        let task = Task { await self.prepareOnce() }
        preparing = task
        await task.value
        preparing = nil
    }

    /// Drops the loaded language and prepares the one now chosen, downloading it if needed.
    /// Call between recordings, never during one.
    func changeLanguage() async {
        await preparing?.value
        locale = nil
        format = nil
        languageName = nil
        modelState = .unknown
        await prepare()
    }

    /// Opens the mic immediately, then attaches a new transcriber + analyzer. Returns once the
    /// microphone is delivering sound and the transcriber is listening; throws
    /// `DictationAudioCapture.CaptureError` when the microphone fails or doesn't respond.
    func start() async throws {
        if capture != nil || attaching != nil { await cancel() }
        let started = Date()

        // `start()` only queues the hardware work, so the main actor never waits on the
        // microphone; the transcriber attaches while it opens.
        let capture = DictationAudioCapture()
        capture.onLevel = Self.onMain { [weak self] level in self?.onLevel(level) }
        let audio = capture.start()
        self.capture = capture

        let generation = self.generation
        let task = Task { try await self.attachTranscriber(to: audio, generation: generation, started: started) }
        attaching = task
        do {
            try await capture.waitUntilRunning()
        } catch {
            // Say so now, without waiting for the transcriber: it may be loading the model.
            // The new generation tells it to stand down, and `attaching` stays set so the next
            // call waits for it to finish doing so.
            self.generation += 1
            if self.capture === capture { stopCapture() }
            throw error
        }
        do {
            try await task.value
        } catch {
            if self.capture === capture { stopCapture() }
            if attaching == task { attaching = nil }
            throw error
        }
    }

    /// Stops the mic, finishes the analyzer, waits for the results to drain, returns cleaned text.
    func finish() async -> String {
        let started = Date()
        stopCapture()
        _ = try? await attaching?.value
        attaching = nil
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let session = session as? DictationTranscriptionSession {
            self.session = nil
            let text = await session.finish()
            log(String(format: "finished in %.2fs, %d characters", Date().timeIntervalSince(started), text.count))
            return text
        }
        #endif
        return ""
    }

    /// Stops everything and throws the audio away.
    func cancel() async {
        generation += 1
        stopCapture()
        _ = try? await attaching?.value
        attaching = nil
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let session = session as? DictationTranscriptionSession {
            self.session = nil
            await session.cancel()
        }
        #endif
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        onLevel(0)
    }

    private func log(_ message: String) {
        DebugLog.shared.log("Dictation: \(message)")
    }

    /// Wraps a main-actor callback so it can be called from the audio thread or a results task.
    /// Formed in a nonisolated function on purpose: a closure written inside a main-actor method
    /// would itself be main-actor, and calling it from the audio thread traps in the Xcode build.
    /// The main queue keeps the calls in order, so an older partial never overwrites a newer one.
    nonisolated private static func onMain<Value: Sendable>(
        _ body: @escaping @MainActor (Value) -> Void
    ) -> @Sendable (Value) -> Void {
        { value in DispatchQueue.main.async { MainActor.assumeIsolated { body(value) } } }
    }

    // MARK: macOS 26

    private func prepareOnce() async {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            await prepareSpeech()
            return
        }
        #endif
        log("needs macOS 26 and a build with its SDK")
    }

    private func attachTranscriber(to audio: AsyncStream<AVAudioPCMBuffer>, generation: Int, started: Date) async throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if format == nil || modelState != .ready { await prepare() }
            guard generation == self.generation else { return }
            guard let locale, let format else { throw EngineError.unavailable }
            let session = DictationTranscriptionSession(
                locale: locale, format: format, onText: Self.onMain { [weak self] text in self?.onPartial(text) })
            self.session = session
            do {
                try await session.start(audio: audio)
            } catch {
                self.session = nil
                log("could not start the transcriber: \(error.localizedDescription)")
                throw error
            }
            // Called off while the analyzer was getting ready (the microphone failed): nothing
            // will feed this session, so don't leave it holding the model open.
            guard generation == self.generation else {
                if self.session === session { self.session = nil }
                await session.cancel()
                return
            }
            log(String(format: "listening, transcriber attached after %.2fs", Date().timeIntervalSince(started)))
            return
        }
        #endif
        throw EngineError.unavailable
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func prepareSpeech() async {
        let started = Date()
        guard SpeechTranscriber.isAvailable else {
            languageName = nil
            modelState = .failed("Needs a Mac with Apple silicon.")
            return
        }
        guard let locale = await DictationSpeechSupport.resolveLocale() else {
            languageName = nil
            modelState = .failed("Your language isn't supported.")
            return
        }
        self.locale = locale
        languageName = DictationLanguage.name(for: locale.identifier)

        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        do {
            if !(await DictationSpeechSupport.isInstalled(locale, for: transcriber)) { modelState = .notInstalled }
            // Asked every time: it returns nil when there is nothing to download, which is the
            // more reliable answer of the two.
            await makeRoomForReservation(of: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("downloading the \(locale.identifier) speech model")
                try await download(request)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                modelState = .failed("The speech model has no audio format.")
                return
            }
            // A throwaway analyzer loads the model now, so the first press doesn't wait for it.
            let warm = SpeechAnalyzer(modules: [transcriber], options: DictationSpeechSupport.analyzerOptions)
            try await warm.prepareToAnalyze(in: format)
            self.format = format
            modelState = .ready
            log(String(format: "\(locale.identifier) model ready in %.2fs", Date().timeIntervalSince(started)))
        } catch {
            modelState = .failed(error.localizedDescription)
            log("model setup failed: \(error.localizedDescription)")
        }
    }

    /// An app may only hold a few languages at once, and each one switched to takes a place.
    /// When they are all taken, give one other than `locale` back, so the download can go ahead.
    @available(macOS 26.0, *)
    private func makeRoomForReservation(of locale: Locale) async {
        let wanted = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        guard reserved.count >= AssetInventory.maximumReservedLocales,
              !reserved.contains(where: { $0.identifier(.bcp47) == wanted }),
              let spare = reserved.first(where: { $0.identifier(.bcp47) != wanted }) else { return }
        await AssetInventory.release(reservedLocale: spare)
        log("released the \(spare.identifier) speech model to make room")
    }

    /// Downloads the model, reporting progress four times a second while it runs.
    @available(macOS 26.0, *)
    private func download(_ request: AssetInstallationRequest) async throws {
        modelState = .downloading(0)
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                self?.modelState = .downloading(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progress.cancel() }
        try await request.downloadAndInstall()
    }
    #endif
}
