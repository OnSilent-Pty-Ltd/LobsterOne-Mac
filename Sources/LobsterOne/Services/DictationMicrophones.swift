import AVFoundation
import Foundation

/// Which microphone dictation listens to. The system default is the usual answer, but not
/// always the right one: a MacBook with its lid closed keeps the built-in microphone as the
/// default and that microphone hears nothing, so the person needs a way to pick the webcam
/// or headset instead.
nonisolated enum DictationMicrophones {
    struct Microphone: Equatable, Identifiable {
        /// The capture device's unique ID (Core Audio's UID); stable across restarts and replugging.
        let uid: String
        let name: String
        var id: String { uid }
    }

    static let selectedKey = "dictationMicrophoneUID"

    /// The chosen microphone's UID; nil follows the system default.
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }

    /// Every microphone connected right now, built-in first.
    static func available() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { Microphone(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// The name of the microphone macOS would use by default.
    static var systemDefaultName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// The microphone to record from: the one with `uid`, or the system default when nothing is
    /// chosen or the chosen one is unplugged right now. The choice is kept, so it comes back
    /// when the microphone does. Nil when there is no microphone at all.
    static func captureDevice(forUID uid: String?) -> AVCaptureDevice? {
        if let uid, let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) { return device }
        return AVCaptureDevice.default(for: .audio)
    }
}
