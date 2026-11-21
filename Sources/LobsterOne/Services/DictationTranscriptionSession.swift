import AVFoundation
import Foundation
#if compiler(>=6.2)
import Speech
#endif

#if compiler(>=6.2)

/// Shared plumbing for Apple's on-device speech model (macOS 26+).
@available(macOS 26.0, *)
nonisolated enum DictationSpeechSupport {
    /// The language to transcribe in: the one chosen in Settings, else the system language,
    /// when the model covers it; otherwise US English. Resolved through `supportedLocale(equivalentTo:)`, never by comparing BCP-47
    /// strings: a region override such as `en-US-u-rg-auzzzz` matches nothing in the list.
    static func resolveLocale(preferred: Locale = DictationLanguage.preferredLocale) async -> Locale? {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) { return locale }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    /// Plain transcription with live (volatile) results, which the HUD shows and "Type as you
    /// speak" types while the person talks. No timing attributes: the text is all we use.
    ///
    /// `.fastResults` is what makes the live text live. Without it the first words arrived
    /// 3.9 s into a recording and then in bursts; with it, 1.0 s in and about every second
    /// after (measured feeding a clip at real-time speed). The finished sentences were the same.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Whether the model for `locale` is already on this Mac. `AssetInventory.status` alone is not
    /// enough: on macOS 26.3 it says `.supported` for a model that is installed but not yet
    /// reserved by this app, while `installedLocales` lists it. Both locales here come from the
    /// framework itself, so comparing their identifiers is safe.
    static func isInstalled(_ locale: Locale, for transcriber: SpeechTranscriber) async -> Bool {
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return true }
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Keep the model loaded for the life of the app, so the second press is as quick as the first.
    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
}

/// Turns a stream of microphone buffers into text, for one recording.
///
/// Kept apart from the microphone so a test can feed it a file. A new transcriber and analyzer
/// are made per recording because an analyzer cannot take a second input sequence.
@available(macOS 26.0, *)
actor DictationTranscriptionSession {
    /// How long to wait for the last words after the input ends before giving up on them, for
    /// a recording of `seconds` of audio.
    ///
    /// The analyzer can fall behind on a long recording, so at release it may still hold a
    /// backlog proportional to the length; a flat limit would cut off the end of what was said.
    /// It runs many times faster than real time, so a quarter of the length is plenty, on top
    /// of five seconds for the model to commit its last words. Capped so a hung model still
    /// lets the person go within half a minute.
    nonisolated static func drainTimeout(forAudio seconds: Double) -> Duration {
        .seconds(min(5 + max(seconds, 0) / 4, 30))
    }

    private let locale: Locale
    private let format: AVAudioFormat
    private let onText: @Sendable (String) -> Void

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var pump: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var finals = ""
    private var volatile = ""
    /// How much audio this recording has handed the analyzer, which sets the drain timeout.
    private let fed = AudioDuration()

    /// `format` is the analyzer's own format (`bestAvailableAudioFormat`); buffers in any other
    /// format are converted to it. `onText` gets the text so far (finals plus the current
    /// volatile guess) on whatever thread the results arrive on.
    init(locale: Locale, format: AVAudioFormat, onText: @escaping @Sendable (String) -> Void = { _ in }) {
        self.locale = locale
        self.format = format
        self.onText = onText
    }

    /// Prepares a fresh analyzer and starts reading `audio`. Buffers already waiting in the
    /// stream are transcribed too, so nothing said before this returns is lost.
    func start(audio: AsyncStream<AVAudioPCMBuffer>) async throws {
        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: DictationSpeechSupport.analyzerOptions)
        try await analyzer.prepareToAnalyze(in: format)

        let (inputSequence, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.analyzer = analyzer
        self.input = input

        results = Task {
            do {
                for try await result in transcriber.results {
                    self.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { DebugLog.shared.log("Dictation: transcription stopped with an error") }
            }
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            input.finish()
            results?.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let target = format
        let fed = self.fed
        pump = Task.detached(priority: .userInitiated) {
            let converter = DictationAudioConverter(to: target)
            for await buffer in audio {
                if Task.isCancelled { break }
                fed.add(buffer)
                if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
            }
            input.finish()
        }
    }

    /// Call after the audio stream has ended (the microphone is stopped). Transcribes what is
    /// left, waits for the model to commit its last words, and returns the cleaned text.
    ///
    /// The results task is left to end on its own after `finalizeAndFinishThroughEndOfInput`;
    /// cancelling it straight after finalize drops the last words. If the model hangs, it is
    /// cut off after `drainTimeout(forAudio:)` and whatever was heard is returned.
    func finish() async -> String {
        guard let analyzer else { return "" }
        let pump = self.pump, results = self.results, input = self.input, fed = self.fed

        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await pump?.value
                input?.finish()
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                return true
            }
            group.addTask {
                // The pump may still be counting the audio queued at release, so the limit is
                // worked out again as it grows rather than fixed at the start.
                let clock = ContinuousClock()
                let start = clock.now
                while clock.now - start < Self.drainTimeout(forAudio: fed.seconds) {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return false }
                }
                return false
            }
            let drained = await group.next() ?? false
            if !drained {
                // Unblock the first child, which the group waits for before returning.
                pump?.cancel()
                input?.finish()
                await analyzer.cancelAndFinishNow()
                results?.cancel()
            }
            group.cancelAll()
            return drained
        }
        if !drained {
            await MainActor.run { DebugLog.shared.log("Dictation: last words timed out, kept what was heard") }
        }

        clear()
        return DictationText.clean(finals + volatile)
    }

    /// Stops at once and throws the audio away.
    func cancel() async {
        guard let analyzer else { return }
        pump?.cancel()
        input?.finish()
        await analyzer.cancelAndFinishNow()
        results?.cancel()
        await pump?.value
        await results?.value
        clear()
        finals = ""
        volatile = ""
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finals += text
            volatile = ""
        } else {
            volatile = text
        }
        onText(finals + volatile)
    }

    private func clear() {
        analyzer = nil
        input = nil
        pump = nil
        results = nil
    }
}

/// Seconds of audio counted by the pump task and read by `finish()`, on different threads.
nonisolated private final class AudioDuration: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Double = 0

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func add(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        total += duration
        lock.unlock()
    }
}

/// Converts microphone buffers to the analyzer's format (16 kHz mono Int16 on current Macs).
/// One per recording, used from a single task. Not main-actor: it runs on the pump task.
nonisolated final class DictationAudioConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(to target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == target { return buffer }
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // No priming: we feed a live stream in pieces, and priming would add silence
            // (and drift) at the start of every piece.
            converter?.primeMethod = .none
            source = buffer.format
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, 1)) else { return nil }

        // Hand the buffer over once, then say there is no more for now, which keeps the
        // converter's state for the next buffer instead of flushing it as end of stream.
        // The block is typed @Sendable but runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let pending = buffer
        nonisolated(unsafe) var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return pending
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

#endif
