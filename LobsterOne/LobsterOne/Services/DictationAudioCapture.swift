import AVFoundation
import CoreMedia
import Foundation

/// Microphone to buffers, for one recording.
///
/// Make a new one per recording and drop it afterwards: a session that stays allocated keeps
/// the input device open, which holds a Bluetooth headset in its low-quality call mode.
///
/// Built on `AVCaptureSession` rather than `AVAudioEngine`. Pointing an engine's input node at
/// a chosen microphone posts a configuration change that, with several microphones attached
/// (a closed MacBook, a USB webcam, an iPhone), livelocked AVFAudio inside `inputNode` and froze
/// the app. A capture session takes the chosen device directly and has no input node.
///
/// Nothing that touches the hardware runs on the caller's thread. Building the session,
/// `startRunning()`, `stopRunning()` and teardown all happen on `sessionQueue`, so a call that
/// hangs inside Core Audio stalls that queue and nothing else. Each recording has its own
/// capture and its own queue, so a stuck one doesn't hold up the next.
///
/// This type is deliberately not main-actor. Its blocks and delegate callbacks run on private
/// queues; in the Xcode target, where code defaults to the main actor, a closure formed in a
/// main-actor method would be checked for main-thread isolation when it runs and trap. All of
/// them are formed here, in nonisolated code. `start()` and `stop()` are called from one thread
/// (the main actor, in practice), `start()` at most once.
nonisolated final class DictationAudioCapture: @unchecked Sendable {
    enum CaptureError: Error {
        /// No microphone, or the session wouldn't take it.
        case noInput
        /// The microphone didn't deliver any sound within `startTimeout`.
        case timedOut
    }

    /// Called on the sample queue with a 0…1 level, at most `levelInterval` apart.
    var onLevel: (@Sendable (Float) -> Void)?

    static let levelInterval: TimeInterval = 1.0 / 30
    /// A working microphone delivers its first buffer in well under a second. Three seconds
    /// covers a slow Bluetooth handshake and is still short enough to say something useful
    /// while the person is holding the key.
    static let startTimeout: TimeInterval = 3

    private let sessionQueue = DispatchQueue(label: "com.lobsterone.dictation.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.lobsterone.dictation.capture.samples")
    private let lifecycle = Lifecycle()

    // Touched only on `sessionQueue`.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var delegate: SampleDelegate?
    private var observers: [NSObjectProtocol] = []

    /// Starts opening the microphone and returns its buffers straight away; the caller never
    /// waits on the hardware. The stream buffers without limit, so audio captured while the
    /// speech analyzer is still getting ready is kept rather than dropped; that is what stops
    /// the first words being clipped. The stream ends on `stop()`, when the microphone fails
    /// or goes away mid-recording, or after `startTimeout` without sound.
    /// `waitUntilRunning()` says which.
    func start() -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let lifecycle = self.lifecycle
        lifecycle.attach(continuation)
        let delegate = SampleDelegate(lifecycle: lifecycle, meter: LevelMeter(interval: Self.levelInterval),
                                      onLevel: onLevel)
        let uid = DictationMicrophones.selectedUID
        sessionQueue.async { self.open(uid: uid, delegate: delegate) }

        // From a global queue, not `sessionQueue`: a hung hardware call there would hold the
        // watchdog up too.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.startTimeout) {
            if lifecycle.fail(.timedOut) {
                Task { @MainActor in DebugLog.shared.log("Dictation: the microphone sent nothing in \(Int(Self.startTimeout))s, gave up") }
            }
        }
        return stream
    }

    /// Returns once the microphone has delivered its first buffer, or the capture was stopped.
    /// Throws `CaptureError` when it failed or timed out first.
    func waitUntilRunning() async throws {
        try await lifecycle.waitUntilRunning()
    }

    /// Ends the buffer stream at once and releases the microphone in the background. Buffers
    /// already yielded stay in the stream for the reader to drain. Never waits on the
    /// hardware, so it returns even when `sessionQueue` is stuck; the teardown then runs
    /// whenever the queue frees up, or never if it doesn't, which leaks one session rather
    /// than freezing the app. Safe to call more than once.
    func stop() {
        lifecycle.stop()
        sessionQueue.async { self.teardown() }
    }

    // MARK: Session queue

    private func open(uid: String?, delegate: SampleDelegate) {
        // Stopped before the queue got here (a quick press): don't touch the hardware at all.
        guard !lifecycle.isOver else { return }
        guard let device = DictationMicrophones.captureDevice(forUID: uid),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return failToOpen("no microphone") }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Float32, one buffer per channel, at whatever rate and channel count the device runs
        // at: the layout `DictationAudioMath` reads directly. Asking for a rate or a channel
        // count would put a converter in the capture path for no gain; the transcription
        // session converts once, to the analyzer's format.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return failToOpen("the session wouldn't take \(device.localizedName)")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return failToOpen("the session wouldn't take an audio output")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        session.commitConfiguration()

        self.session = session
        self.output = output
        self.delegate = delegate
        observe(session, device)

        session.startRunning()
        let name = device.localizedName
        Task { @MainActor in DebugLog.shared.log("Dictation: microphone open (\(name))") }
        // A `stop()` that came in while `startRunning()` was busy queued its teardown behind
        // this block, so there is nothing more to do here.
    }

    private func failToOpen(_ reason: String) {
        if lifecycle.fail(.noInput) {
            Task { @MainActor in DebugLog.shared.log("Dictation: couldn't open the microphone, \(reason)") }
        }
    }

    /// A device that goes away mid-recording ends it; the person still gets what was said so
    /// far. Both notifications are scoped to this session and this device, so another app's
    /// microphone or another recording can't end this one.
    private func observe(_ session: AVCaptureSession, _ device: AVCaptureDevice) {
        let lifecycle = self.lifecycle
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { @Sendable notification in
            // Only a session that has actually stopped ends the recording. Ending it on a
            // notice that left capture running once lost every word after it (see b034793).
            if (notification.object as? AVCaptureSession)?.isRunning == true { return }
            if lifecycle.end(.noInput) {
                Task { @MainActor in DebugLog.shared.log("Dictation: the microphone stopped with an error, recording ended") }
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil
        ) { @Sendable _ in
            if lifecycle.end(.noInput) {
                Task { @MainActor in DebugLog.shared.log("Dictation: microphone disconnected, recording ended") }
            }
        })
    }

    private func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil
        output = nil
        delegate = nil
    }
}

/// Where one recording's capture stands, shared by the caller, the session queue, the sample
/// queue, the watchdog and the notification handlers. Owns the stream's continuation so the
/// stream ends exactly once, whichever of them gets there first.
nonisolated private final class Lifecycle: @unchecked Sendable {
    private enum Phase {
        case opening, running, over
    }

    private let lock = NSLock()
    private var phase = Phase.opening
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    /// Set when the capture ended before its first buffer; what `waitUntilRunning()` throws.
    private var failure: DictationAudioCapture.CaptureError?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func attach(_ continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    var isOver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .over
    }

    /// From the sample queue. Returns false once the stream has ended, so the caller can skip
    /// the level report too.
    func yield(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        guard phase != .over, let continuation else {
            lock.unlock()
            return false
        }
        continuation.yield(buffer)
        let first = phase == .opening
        phase = .running
        let waiters = first ? takeWaiters() : []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
        return true
    }

    /// Ends the capture before it ever delivered sound. Returns whether this call did it: a
    /// capture that is already running or over is left alone, so a late watchdog is harmless.
    @discardableResult
    func fail(_ error: DictationAudioCapture.CaptureError) -> Bool {
        lock.lock()
        guard phase == .opening else {
            lock.unlock()
            return false
        }
        failure = error
        return close()
    }

    /// Ends the capture whatever its phase: a failure before the first buffer, the end of the
    /// recording after it. Returns whether this call did it.
    @discardableResult
    func end(_ error: DictationAudioCapture.CaptureError) -> Bool {
        lock.lock()
        guard phase != .over else {
            lock.unlock()
            return false
        }
        if phase == .opening { failure = error }
        return close()
    }

    /// The caller is done with the recording. Not a failure.
    func stop() {
        lock.lock()
        guard phase != .over else {
            lock.unlock()
            return
        }
        _ = close()
    }

    func waitUntilRunning() async throws {
        // A cancelled wait means the recording is being abandoned; ending the capture is what
        // the caller would do next anyway, and it releases this wait.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                lock.lock()
                switch phase {
                case .opening:
                    waiters.append(waiter)
                    lock.unlock()
                case .running:
                    lock.unlock()
                    waiter.resume()
                case .over:
                    let failure = self.failure
                    lock.unlock()
                    if let failure { waiter.resume(throwing: failure) } else { waiter.resume() }
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Called with the lock held; releases it.
    private func close() -> Bool {
        phase = .over
        let continuation = self.continuation
        self.continuation = nil
        let waiters = takeWaiters()
        let failure = self.failure
        lock.unlock()
        continuation?.finish()
        for waiter in waiters {
            if let failure { waiter.resume(throwing: failure) } else { waiter.resume() }
        }
        return true
    }

    private func takeWaiters() -> [CheckedContinuation<Void, Error>] {
        let waiters = self.waiters
        self.waiters = []
        return waiters
    }
}

/// Receives the session's sample buffers on the sample queue. An NSObject because the
/// delegate protocol asks for one; kept apart from `DictationAudioCapture` so the capture
/// itself needn't be.
nonisolated private final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lifecycle: Lifecycle
    private let meter: LevelMeter
    private let onLevel: (@Sendable (Float) -> Void)?
    private var loggedFormat = false

    init(lifecycle: Lifecycle, meter: LevelMeter, onLevel: (@Sendable (Float) -> Void)?) {
        self.lifecycle = lifecycle
        self.meter = meter
        self.onLevel = onLevel
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = DictationAudioMath.pcmBuffer(from: sampleBuffer) else { return }
        if !loggedFormat {
            loggedFormat = true
            // What the device actually delivers is the one thing tests can't see; the log can.
            let format = buffer.format
            let samples = format.commonFormat == .pcmFormatFloat32 ? "Float32" : "sample format \(format.commonFormat.rawValue)"
            let description = String(format: "%.0f Hz, %d channels, ", format.sampleRate, format.channelCount)
                + samples + (format.isInterleaved ? ", interleaved" : "")
            Task { @MainActor in DebugLog.shared.log("Dictation: microphone delivers \(description)") }
        }
        let mono = DictationAudioMath.mono(buffer)
        guard lifecycle.yield(mono) else { return }
        if let onLevel, meter.isDue() {
            onLevel(DictationAudioMath.level(of: mono))
        }
    }
}

/// Throttles level reports so the HUD redraws at a steady rate whatever the buffer size.
nonisolated private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last: TimeInterval = 0

    init(interval: TimeInterval) { self.interval = interval }

    func isDue() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}

/// Sample arithmetic for the capture path. Pure, so it runs on the sample queue and in tests.
nonisolated enum DictationAudioMath {
    /// Copies a capture sample buffer into an `AVAudioPCMBuffer` in the format it arrived in.
    /// Nil for anything that isn't linear PCM or is empty.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        var asbd = basic.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, frames > 0 else { return nil }

        let format: AVAudioFormat?
        if asbd.mChannelsPerFrame > 2 {
            // `AVAudioFormat` refuses more than two channels without a layout. Echo-cancelled
            // input can arrive like that; the channels are averaged later, so any layout will do.
            var layoutSize = 0
            let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
                .map { AVAudioChannelLayout(layout: $0) }
                ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
            format = layout.flatMap { AVAudioFormat(streamDescription: &asbd, channelLayout: $0) }
        } else {
            format = AVAudioFormat(streamDescription: &asbd)
        }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }

    /// One Float32 channel from whatever the microphone delivered: channels averaged, integer
    /// samples scaled to ±1, interleaved or not. Mono Float32 passes through untouched; a format
    /// it can't read (not 16- or 32-bit integer or Float32) passes through too.
    ///
    /// The capture asks for Float32, but a device is free to ignore that, and the meter and the
    /// "microphone was silent" check read Float32 only: an integer buffer let through would
    /// read as silence for the whole recording.
    ///
    /// When another app turns on echo cancellation for the shared microphone (meeting apps do),
    /// the input can arrive as several channels with no channel layout. `AVAudioConverter`
    /// turns that into silence when asked for mono, so the channels are averaged here instead.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let common = buffer.format.commonFormat
        if common == .pcmFormatFloat32, channels == 1 { return buffer }

        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let sample: (Int, Int) -> Float
        switch common {
        case .pcmFormatFloat32:
            guard let source = buffer.floatChannelData else { return buffer }
            sample = { channel, frame in interleaved ? source[0][frame * stride + channel] : source[channel][frame] }
        case .pcmFormatInt16:
            guard let source = buffer.int16ChannelData else { return buffer }
            sample = { channel, frame in
                Float(interleaved ? source[0][frame * stride + channel] : source[channel][frame]) / 32_768
            }
        case .pcmFormatInt32:
            guard let source = buffer.int32ChannelData else { return buffer }
            sample = { channel, frame in
                Float(interleaved ? source[0][frame * stride + channel] : source[channel][frame]) / 2_147_483_648
            }
        default:
            return buffer
        }
        guard channels > 0, frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0]
        else { return buffer }

        output.frameLength = AVAudioFrameCount(frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += sample(channel, frame) }
            destination[frame] = sum * scale
        }
        return output
    }

    /// 0…1 loudness of the first channel, for the meter. Expects what `mono` returns; 0 for
    /// non-float buffers.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for i in 0..<frames { sumOfSquares += samples[i] * samples[i] }
        return level(rms: (sumOfSquares / Float(frames)).squareRoot())
    }

    /// Speech sits roughly between -50 dB (a quiet room) and -10 dB (talking close to the mic).
    /// Mapping that window, not the full range, keeps normal speech from bunching up at the
    /// bottom of the meter; the square root lifts the quiet end a little further.
    static func level(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        let floor: Float = -50, ceiling: Float = -10
        let linear = (min(max(decibels, floor), ceiling) - floor) / (ceiling - floor)
        return linear.squareRoot()
    }
}
