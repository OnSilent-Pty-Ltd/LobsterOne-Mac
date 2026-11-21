import AppKit
import Security
import UserNotifications

/// Apple push for town invites. Off unless the build is signed with the
/// `com.apple.developer.aps-environment` entitlement (which needs a provisioning profile from the
/// owner's developer account); without it nothing is registered and nothing is logged as an error,
/// and the 5 to 15 minute poll stays the only path.
@MainActor
final class PushRegistration {
    private var apiKey: String?
    private(set) var token: String?
    private var loggedMissingEntitlement = false
    private var timeZoneObserver: NSObjectProtocol?

    init() {
        // Quiet hours follow the Mac: travel or a manual change re-sends the zone.
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sendToken() }
        }
    }

    /// "development" or "production" as signed into this build, nil when push isn't set up.
    nonisolated static func apsEnvironment() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil)
        else { return nil }
        return value as? String
    }

    /// Register this Mac for town invite pushes. Safe to call repeatedly.
    func start(apiKey: String) {
        self.apiKey = apiKey
        guard TownInviteNotifier.isEnabled, Bundle.main.bundleIdentifier != nil else { return }
        guard Self.apsEnvironment() != nil else {
            if !loggedMissingEntitlement {
                DebugLog.shared.log("Push not set up in this build; town invites arrive by poll")
                loggedMissingEntitlement = true
            }
            return
        }
        Task {
            // Alert pushes only show once notifications are allowed.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            NSApp.registerForRemoteNotifications()
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        DebugLog.shared.log("Push registered (token …\(hex.suffix(6)))")
        sendToken()
    }

    /// PUT the token with the current zone. Runs on every registration (each app start) and
    /// whenever the system time zone changes.
    private func sendToken() {
        guard TownInviteNotifier.isEnabled, let token, let apiKey, let device = device(token) else { return }
        Task {
            // An older backend answers 404; the poll still works, so this is only logged.
            try? await APIClient(apiKey: apiKey).sendAPNsDevice(device, method: "PUT")
        }
    }

    func didFail(_ error: Error) {
        DebugLog.shared.log("Push registration failed: \(error.localizedDescription)")
    }

    /// Stop pushes to this Mac: the switch went off or the person signed out.
    /// `apiKey` is passed in on sign-out, where the keychain is about to be wiped.
    func unregister(apiKey key: String? = nil) async {
        guard let token, let key = key ?? apiKey, let device = device(token) else { return }
        try? await APIClient(apiKey: key).sendAPNsDevice(device, method: "DELETE")
    }

    private func device(_ token: String) -> APNsDeviceRequest? {
        guard let environment = Self.apsEnvironment() else { return nil }
        NSTimeZone.resetSystemTimeZone()
        return APNsDeviceRequest(token: token, environment: environment, timeZone: TimeZone.current.identifier)
    }

    /// Ids in a background `{ "town_clear": [...] }` push.
    nonisolated static func clearedInviteIds(_ userInfo: [AnyHashable: Any]) -> [String]? {
        guard let raw = userInfo["town_clear"] as? [Any] else { return nil }
        return raw.compactMap { item in
            if let text = item as? String { return text }
            if let number = item as? NSNumber { return number.stringValue }
            return nil
        }
    }
}
