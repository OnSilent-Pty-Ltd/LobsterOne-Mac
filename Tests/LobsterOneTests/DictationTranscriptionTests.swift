import AVFoundation
import CoreMedia
import XCTest
#if compiler(>=6.2)
import Speech
#endif
@testable import LobsterOne

/// XCTest rather than Swift Testing for the `XCTSkip`: the integration test has to stand down,
/// not fail, on CI runners without macOS 26 or the speech model.
final class DictationTranscriptionTests: XCTestCase {
    // MARK: Capture arithmetic

    func testLevelIsZeroForSilenceAndFullForLoudSpeech() {
        XCTAssertEqual(DictationAudioMath.level(rms: 0), 0)
        XCTAssertEqual(DictationAudioMath.level(rms: 1), 1)
        let talking = DictationAudioMath.level(rms: 0.03)   // about -30 dB
        XCTAssertGreaterThan(talking, 0.5)
        XCTAssertLessThan(talking, 1)
    }

    func testMonoAveragesStereoChannels() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4))
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData![0][frame] = 0.5
            buffer.floatChannelData![1][frame] = -0.1
        }
        let mono = DictationAudioMath.mono(buffer)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 4)
        XCTAssertEqual(mono.floatChannelData![0][2], 0.2, accuracy: 1e-6)
    }

    /// A device that ignores the Float32 request must still read as sound, not silence.
    func testMonoReadsInterleavedIntegerSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = buffer.int16ChannelData![0]
        for frame in 0..<4 {
            samples[frame * 2] = 16_384        // 0.5
            samples[frame * 2 + 1] = -3_277    // about -0.1
        }
        let mono = DictationAudioMath.mono(buffer)
        XCTAssertEqual(mono.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 4)
        XCTAssertEqual(mono.floatChannelData![0][1], 0.2, accuracy: 1e-3)
        XCTAssertGreaterThan(DictationAudioMath.level(of: mono), 0.5)
    }

    func testMonoPassesMonoFloatThrough() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        XCTAssertTrue(DictationAudioMath.mono(buffer) === buffer)
    }

    /// The capture path: a sample buffer as `AVCaptureAudioDataOutput` hands it over, in the
    /// format the capture asks for and in one a device might send instead.
    func testSampleBuffersBecomePCMBuffers() throws {
        let planar = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: 512))
        source.frameLength = 512
        for frame in 0..<512 {
            source.floatChannelData![0][frame] = 0.5
            source.floatChannelData![1][frame] = -0.1
        }
        let converted = try XCTUnwrap(DictationAudioMath.pcmBuffer(from: try Self.sampleBuffer(from: source)))
        XCTAssertEqual(converted.format, planar)
        XCTAssertEqual(converted.frameLength, 512)
        let mono = DictationAudioMath.mono(converted)
        XCTAssertEqual(mono.floatChannelData![0][511], 0.2, accuracy: 1e-6)

        let interleaved = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let integers = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 256))
        integers.frameLength = 256
        for frame in 0..<256 { integers.int16ChannelData![0][frame] = 8_192 }   // 0.25
        let fromIntegers = try XCTUnwrap(DictationAudioMath.pcmBuffer(from: try Self.sampleBuffer(from: integers)))
        let monoFromIntegers = DictationAudioMath.mono(fromIntegers)
        XCTAssertEqual(monoFromIntegers.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(monoFromIntegers.floatChannelData![0][100], 0.25, accuracy: 1e-4)
    }

    // MARK: Transcription, end to end

    /// Speaks a sentence with `say`, feeds the file through the session in microphone-sized
    /// pieces (the same path the mic takes, converter included) and checks words come back.
    func testTranscribesSpokenClip() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        guard SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber is not available on this Mac") }
        guard let locale = await DictationSpeechSupport.resolveLocale(preferred: Locale(identifier: "en-US")) else {
            throw XCTSkip("No English speech model")
        }
        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        guard await DictationSpeechSupport.isInstalled(locale, for: transcriber) else {
            throw XCTSkip("The \(locale.identifier) speech model is not installed")
        }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let format = try XCTUnwrap(best)
        let clip = try Self.say("The quick brown fox jumps over the lazy dog. Please commit the changes and open a pull request.")
        defer { try? FileManager.default.removeItem(at: clip) }

        let partials = PartialCount()
        let session = DictationTranscriptionSession(locale: locale, format: format) { _ in partials.bump() }
        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)

        // Some audio is queued before the session starts, as when the mic opens first.
        let file = try AVAudioFile(forReading: clip)
        try Self.feed(file, to: continuation, upTo: 4)
        try await session.start(audio: audio)
        try Self.feed(file, to: continuation, upTo: .max)
        continuation.finish()

        let text = await session.finish().lowercased()
        for word in ["quick brown fox", "lazy dog", "commit"] {
            XCTAssertTrue(text.contains(word), "missing \"\(word)\" in: \(text)")
        }
        XCTAssertFalse(text.contains("\n"))
        XCTAssertGreaterThan(partials.value, 0, "no live text was reported")
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    /// The language chosen in Settings, not the system's, is the one transcribed: French spoken
    /// to the French model comes back as French. Set DICTATION_DOWNLOAD=1 to fetch the model.
    func testTranscribesFrenchWhenFrenchIsChosen() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        guard SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber is not available on this Mac") }
        let saved = DictationLanguage.selectedIdentifier
        DictationLanguage.selectedIdentifier = "fr-FR"
        defer { DictationLanguage.selectedIdentifier = saved }
        let resolved = await DictationSpeechSupport.resolveLocale()
        let locale = try XCTUnwrap(resolved)
        XCTAssertTrue(locale.identifier(.bcp47).hasPrefix("fr"), "resolved to \(locale.identifier)")

        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        if !(await DictationSpeechSupport.isInstalled(locale, for: transcriber)) {
            guard ProcessInfo.processInfo.environment["DICTATION_DOWNLOAD"] == "1" else {
                throw XCTSkip("The \(locale.identifier) speech model is not installed")
            }
            try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
        }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let format = try XCTUnwrap(best)
        let clip = try Self.say("Bonjour, je voudrais ouvrir une demande de fusion pour le projet.", voice: "Thomas")
        defer { try? FileManager.default.removeItem(at: clip) }

        let session = DictationTranscriptionSession(locale: locale, format: format) { _ in }
        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        try await session.start(audio: audio)
        try Self.feed(try AVAudioFile(forReading: clip), to: continuation, upTo: .max)
        continuation.finish()

        let text = await session.finish().lowercased()
        for word in ["bonjour", "je voudrais", "projet"] {
            XCTAssertTrue(text.contains(word), "missing \"\(word)\" in: \(text)")
        }
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    func testDrainAllowanceGrowsWithTheRecording() throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        XCTAssertEqual(DictationTranscriptionSession.drainTimeout(forAudio: 0), .seconds(5))
        XCTAssertEqual(DictationTranscriptionSession.drainTimeout(forAudio: 60), .seconds(20))
        XCTAssertEqual(DictationTranscriptionSession.drainTimeout(forAudio: 600), .seconds(30))
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    /// The worst backlog there can be: a long recording queued in full before the analyzer has
    /// heard any of it, then finished at once, as when the key is released. The end of what was
    /// said must still come back.
    func testLongBacklogComesBackComplete() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        guard SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber is not available on this Mac") }
        guard let locale = await DictationSpeechSupport.resolveLocale(preferred: Locale(identifier: "en-US")) else {
            throw XCTSkip("No English speech model")
        }
        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        guard await DictationSpeechSupport.isInstalled(locale, for: transcriber),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw XCTSkip("The \(locale.identifier) speech model is not installed") }

        let paragraph = "The ferry leaves the harbour at nine and crosses the bay before lunch. "
            + "Passengers watch the gulls and the lighthouse while the engine hums below deck. "
        let script = "Opening words for the record. " + String(repeating: paragraph, count: 9)
            + "And that is the final sentence about purple elephants."
        let clip = try Self.say(script)
        defer { try? FileManager.default.removeItem(at: clip) }
        let file = try AVAudioFile(forReading: clip)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertGreaterThan(seconds, 50, "the clip should be long enough to build a real backlog")

        let session = DictationTranscriptionSession(locale: locale, format: format)
        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        try Self.feed(file, to: continuation, upTo: .max)
        continuation.finish()
        try await session.start(audio: audio)

        let started = Date()
        let text = await session.finish().lowercased()
        let took = Date().timeIntervalSince(started)
        print(String(format: "Backlog of %.0fs drained in %.1fs", seconds, took))
        XCTAssertTrue(text.contains("opening words"), "missing the start in: \(text)")
        XCTAssertTrue(text.contains("purple elephants"), "missing the end in: \(text)")
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    func testCancelReturnsPromptly() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
              let locale = await DictationSpeechSupport.resolveLocale(preferred: Locale(identifier: "en-US"))
        else { throw XCTSkip("SpeechTranscriber is not available") }
        let transcriber = DictationSpeechSupport.makeTranscriber(locale: locale)
        guard await DictationSpeechSupport.isInstalled(locale, for: transcriber),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw XCTSkip("The speech model is not installed") }

        let session = DictationTranscriptionSession(locale: locale, format: format)
        let (audio, _) = AsyncStream<AVAudioPCMBuffer>.makeStream()   // never ends, like a live mic
        try await session.start(audio: audio)
        let started = Date()
        await session.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    func testAvailabilityOnThisMac() async {
        let availability = await DictationSpeechEngine.availability()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            XCTAssertNotEqual(availability, .needsMacOS26)
            return
        }
        #endif
        XCTAssertEqual(availability, .needsMacOS26)
    }

    /// No microphone involved: resolving the language and warming the model.
    @MainActor
    func testPrepareReachesReady() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), await DictationSpeechEngine.availability() == .available,
              let locale = await DictationSpeechSupport.resolveLocale()
        else { throw XCTSkip("Dictation is not available on this Mac") }
        // prepare() would download a missing model; a test run shouldn't.
        guard await DictationSpeechSupport.isInstalled(locale, for: DictationSpeechSupport.makeTranscriber(locale: locale))
        else { throw XCTSkip("The \(locale.identifier) speech model is not installed") }

        let engine = DictationSpeechEngine()
        var states: [DictationModelState] = []
        engine.onModelState = { states.append($0) }
        await engine.prepare()
        XCTAssertEqual(engine.modelState, .ready)
        XCTAssertNotNil(engine.languageName)
        await engine.prepare()   // a second call is a no-op
        XCTAssertEqual(states.last, .ready)
        XCTAssertEqual(states.filter { $0 == .ready }.count, 1)
        #else
        throw XCTSkip("Built without the macOS 26 SDK")
        #endif
    }

    // MARK: Helpers

    private static func say(_ sentence: String, voice: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, sentence]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("`say` could not make a clip") }
        return url
    }

    /// Wraps a PCM buffer in a sample buffer, the way the capture output delivers audio.
    private static func sampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        XCTAssertEqual(status, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertEqual(status, noErr)
        let result = try XCTUnwrap(sample)
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList)
        XCTAssertEqual(status, noErr)
        return result
    }

    /// Reads up to `limit` 2048-frame buffers, the size the microphone tap delivers.
    private static func feed(_ file: AVAudioFile, to continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
                             upTo limit: Int) throws {
        var count = 0
        while file.framePosition < file.length, count < limit {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { return }
            try file.read(into: buffer, frameCount: 2048)
            continuation.yield(buffer)
            count += 1
        }
    }
}

private final class PartialCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
