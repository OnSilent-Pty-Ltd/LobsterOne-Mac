import AppKit
import ApplicationServices
import AVFoundation

/// The two permissions dictation needs: the microphone to hear, and Accessibility to watch the
/// dictation key in other apps and to post the ⌘V. No speech-recognition permission is needed;
/// that only applies to SFSpeechRecognizer, not the on-device SpeechAnalyzer.
@MainActor
enum DictationPermissions {
    enum State: Equatable { case allowed, denied, notAsked }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    /// Shows the macOS prompt if it hasn't been answered yet, and returns the state after.
    static func requestMicrophone() async -> State {
        // macOS kills a process that asks for the microphone without a usage description
        // (e.g. `swift run`, which has no Info.plist), so don't ask at all in that case.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            DebugLog.shared.log("Microphone: not asking, this build has no NSMicrophoneUsageDescription")
            return microphone
        }
        guard microphone == .notAsked else { return microphone }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        DebugLog.shared.log(granted ? "Microphone permission granted" : "Microphone permission declined")
        return microphone
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system's "would like to control this computer" prompt, which links to the
    /// Accessibility list. macOS only shows it when the app isn't trusted yet.
    static func promptAccessibility() {
        // The string value of kAXTrustedCheckOptionPrompt; the imported global is a mutable
        // var that strict concurrency checking refuses to read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Software Update, for a Mac whose macOS is too old for the speech model.
    static func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
