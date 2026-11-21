import AppKit

/// Knows whether the LobsterOne screensaver is on screen, so polling can keep its numbers
/// fresh while someone is looking at them.
@MainActor
final class ScreensaverWatch {
    /// Called when a screensaver starts, so the first fresh figures arrive straight away.
    var onStart: (() -> Void)?

    private var notifiedShowing = false
    private var displaysAsleep = false
    private var observers: [NSObjectProtocol] = []

    /// Nothing to keep fresh unless our screensaver is installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Screen Savers/LobsterOne.saver")
    }

    /// The start notification is not sent on every path, so Apple's engine app counts too.
    var isShowing: Bool {
        guard Self.isInstalled, !displaysAsleep else { return false }
        return notifiedShowing
            || NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").contains { !$0.isTerminated }
    }

    func start() {
        stop()
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping @MainActor (ScreensaverWatch) -> Void) {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self { change(self) } }
            })
        }
        observe(distributed, "com.apple.screensaver.didstart") { watch in
            watch.notifiedShowing = true
            if Self.isInstalled { watch.onStart?() }
        }
        observe(distributed, "com.apple.screensaver.didstop") { $0.notifiedShowing = false }
        observe(distributed, "com.apple.screensaver.willstop") { $0.notifiedShowing = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displaysAsleep = false }
    }

    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        notifiedShowing = false
    }
}
