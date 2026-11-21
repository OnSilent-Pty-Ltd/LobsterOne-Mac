import Foundation
import os
import UserNotifications

/// Posts one Mac notification when a crew member needs the person's eye, with the member's
/// portrait. `CrewKeeper` decides when and makes sure each cause is announced once.
@MainActor
enum CrewNotifier {
    static let enabledKey = "crewAlertsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// UNUserNotificationCenter traps when the process has no bundle (e.g. `swift run`).
    private static var canUseNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    static func announce(_ attention: [CrewAttention]) {
        guard isEnabled, canUseNotifications, !attention.isEmpty else { return }
        Task {
            switch await PaceNotifier.permission() {
            case .allowed: break
            case .notAsked: guard await PaceNotifier.requestPermission() else { return }
            case .denied, .unavailable: return
            }
            for item in attention {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                if let attachment = portrait(item) { content.attachments = [attachment] }
                do {
                    try await UNUserNotificationCenter.current()
                        .add(UNNotificationRequest(identifier: "crew-" + item.id, content: content, trigger: nil))
                    DebugLog.shared.log("Crew alert posted: \(item.title)")
                } catch {
                    DebugLog.shared.log("Crew alert not shown: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The notification centre moves an attachment into its own store, so it gets a copy.
    private static func portrait(_ item: CrewAttention) -> UNNotificationAttachment? {
        guard let face = item.face, let source = CrewPortrait.url(face) else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("crew-\(face)-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: face, url: copy)
        } catch {
            return nil
        }
    }
}
