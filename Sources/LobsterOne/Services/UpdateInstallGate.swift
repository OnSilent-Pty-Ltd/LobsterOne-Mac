import AppKit

/// Holds a downloaded update until relaunching won't be noticed: none of our UI is open and the
/// person has been away from the keyboard and mouse for a while. Sparkle still installs it on
/// quit if that moment never comes.
@MainActor
final class UpdateInstallGate {
    static let requiredIdle: TimeInterval = 3 * 60
    private static let recheckInterval: TimeInterval = 60

    /// True while the popover, Settings or any other window of ours is on screen.
    var isInterfaceOpen: () -> Bool = { false }

    private var pendingInstall: (() -> Void)?
    private var timer: Timer?

    static func canInstall(idleSeconds: TimeInterval, interfaceOpen: Bool) -> Bool {
        !interfaceOpen && idleSeconds >= requiredIdle
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    static var systemIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func hold(_ install: @escaping () -> Void) {
        pendingInstall = install
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installIfQuiet() }
        }
    }

    /// The person asked for updates: install a held one now instead of waiting for them to
    /// step away. Returns false when nothing is waiting, so the caller can run a normal check.
    @discardableResult
    func installNow() -> Bool {
        guard let install = pendingInstall else { return false }
        timer?.invalidate()
        timer = nil
        pendingInstall = nil
        DebugLog.shared.log("Sparkle: installing held update on request")
        install()
        return true
    }

    var hasPendingInstall: Bool { pendingInstall != nil }

    private func installIfQuiet() {
        guard let install = pendingInstall,
              Self.canInstall(idleSeconds: Self.systemIdleSeconds, interfaceOpen: isInterfaceOpen())
        else { return }
        timer?.invalidate()
        timer = nil
        pendingInstall = nil
        DebugLog.shared.log("Sparkle: installing held update while idle")
        install()
    }
}
