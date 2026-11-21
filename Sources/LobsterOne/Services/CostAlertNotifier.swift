import Foundation
import os
import UserNotifications

/// Posts the AWS cost alerts ("Production passed $50"). `CostMonitor` decides when; this only
/// shows them, through the same notification centre and permission as the pace alerts.
/// Clicking one opens the popover, through the delegate `TownInviteNotifier` installs.
@MainActor
final class CostAlertNotifier: AlertNotifying {
    static let enabledKey = "awsCostAlertsEnabled"

    private static let logger = Logger(subsystem: "com.lobsterone.mac", category: "notifications")

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var isEnabled: Bool { Self.isEnabled }

    /// UNUserNotificationCenter traps when the process has no bundle (e.g. `swift run`).
    private static var canUseNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asked when the first alert amount is set, so the prompt comes while the person is
    /// looking, not weeks later when the alert fires.
    func requestPermission() {
        guard Self.isEnabled, Self.canUseNotifications else { return }
        Task {
            if await PaceNotifier.permission() == .notAsked { await PaceNotifier.requestPermission() }
        }
    }

    func notify(id: String, title: String, body: String) {
        guard Self.isEnabled, Self.canUseNotifications else { return }
        Task {
            switch await PaceNotifier.permission() {
            case .allowed:
                break
            case .notAsked:
                guard await PaceNotifier.requestPermission() else { return Self.log("Cost alert not shown: permission not granted", error: true) }
            case .denied:
                return Self.log("Cost alert not shown: notifications are off for LobsterOne in System Settings", error: true)
            case .unavailable:
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            do {
                try await UNUserNotificationCenter.current()
                    .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                Self.log("Cost alert posted: \(title)")
            } catch {
                Self.log("Cost alert not shown: \(error.localizedDescription)", error: true)
            }
        }
    }

    private static func log(_ message: String, error: Bool = false) {
        if error {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        DebugLog.shared.log(message)
    }
}
