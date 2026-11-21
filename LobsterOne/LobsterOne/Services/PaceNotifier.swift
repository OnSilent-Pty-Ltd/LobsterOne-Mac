import Foundation
import os
import UserNotifications

/// Posts a system notification when the pace projects a cap before the 5-hour session or the
/// weekly window resets. Fires at most once per window and limit: the window is identified by its reset time, which is
/// persisted so a relaunch mid-window doesn't alert again. A window only counts as alerted once
/// the notification was actually handed to macOS, so a failed or blocked attempt doesn't silence it.
@MainActor
final class PaceNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "paceNotificationsEnabled"
    private static func lastWindowKey(_ limit: SessionPace.Limit) -> String {
        // The session key predates the weekly alert; keep its name so upgrades don't re-alert.
        limit == .session ? "paceNotificationLastWindow" : "paceNotificationLastWindow.week"
    }
    /// After a failed attempt, wait this long before trying the same window again.
    nonisolated static let retryInterval: TimeInterval = 10 * 60

    private static let logger = Logger(subsystem: "com.lobsterone.mac", category: "notifications")

    private let defaults: UserDefaults
    /// Opens the popover when the person clicks the notification.
    var onOpen: () -> Void = {}
    /// Limits with a post in flight, so overlapping polls don't double-post.
    private var inFlight: Set<SessionPace.Limit> = []
    /// Last failed attempt per limit, to back off instead of retrying every poll.
    private var lastFailure: [SessionPace.Limit: Date] = [:]
    private var askedThisLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        // UNUserNotificationCenter traps when the process has no bundle (e.g. `swift run`).
        if Self.canUseNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var canUseNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: Permission

    enum Permission: Equatable {
        case allowed, denied, notAsked, unavailable

        /// The person has to do something before alerts can appear.
        var needsAction: Bool { self == .denied || self == .notAsked }
    }

    static func permission() async -> Permission {
        guard canUseNotifications else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    /// Shows the macOS prompt if it hasn't been answered yet. Returns whether alerts can be posted.
    @discardableResult
    static func requestPermission() async -> Bool {
        guard canUseNotifications else { return false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            log(granted ? "Notification permission granted" : "Notification permission declined")
            return granted
        } catch {
            log("Notification permission request failed: \(error.localizedDescription)", error: true)
            return false
        }
    }

    /// Ask once per launch, as soon as there's quota to watch, rather than at the moment of the
    /// first alert, when a missed or failed prompt would cost that alert.
    private func askOnceIfNeeded() {
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        Task {
            if await Self.permission() == .notAsked { await Self.requestPermission() }
        }
    }

    // MARK: Alerts

    /// Evaluate the latest quota. Call after every poll.
    func evaluate(_ limit: SessionPace.Limit, percent: Double?, resetsAt: Date?, now: Date = Date()) {
        guard Self.isEnabled, Self.canUseNotifications else { return }
        askOnceIfNeeded()

        guard let percent, let resetsAt,
              let warning = SessionPace.warning(percent: percent, resetsAt: resetsAt, now: now, limit: limit)
        else { return }

        let key = Self.lastWindowKey(limit)
        guard !Self.sameWindow(defaults.object(forKey: key) as? Double, resetsAt),
              !inFlight.contains(limit),
              Self.shouldRetry(lastFailure: lastFailure[limit], now: now)
        else { return }

        let toCap = MenuPopoverView.duration(minutes: warning.minutesToCap)
        let early = MenuPopoverView.duration(minutes: warning.minutesCappedBeforeReset)
        let title = limit == .session ? "Session cap in about \(toCap)" : "Weekly cap in about \(toCap)"
        let body = limit == .session
            ? "At this pace you'll be locked out \(early) before the session resets."
            : "At this pace you'll be locked out \(early) before your weekly limit resets."
        let id = "pace-\(limit.rawValue)-\(Int(resetsAt.timeIntervalSince1970))"

        inFlight.insert(limit)
        Task {
            defer { inFlight.remove(limit) }
            switch await Self.permission() {
            case .allowed:
                break
            case .notAsked:
                guard await Self.requestPermission() else { return fail(limit, "permission not granted") }
            case .denied:
                // Not marked as alerted: if alerts are switched on later in this window, it still fires.
                return fail(limit, "notifications are off for LobsterOne in System Settings")
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
                defaults.set(resetsAt.timeIntervalSince1970, forKey: key)
                lastFailure[limit] = nil
                Self.log("Pace notification posted: \(title)")
            } catch {
                fail(limit, error.localizedDescription)
            }
        }
    }

    /// Posts a sample alert now, asking for permission first if needed. Returns a short line
    /// saying what happened, for Settings to show.
    static func sendTest() async -> String {
        switch await permission() {
        case .unavailable:
            return "Notifications aren't available in this build."
        case .denied:
            return "macOS has notifications off for LobsterOne. Turn them on in System Settings."
        case .notAsked:
            guard await requestPermission() else { return "Permission wasn't granted, so nothing was sent." }
        case .allowed:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = "Session cap in about 1h 30m"
        content.subtitle = "Test alert"
        content.body = "At this pace you'll be locked out 27m before the session resets."
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: "pace-test-\(UUID().uuidString)", content: content, trigger: nil))
            log("Test pace notification posted")
            return "Sent. If no banner appeared, check Focus and the banner style in System Settings."
        } catch {
            log("Test pace notification failed: \(error.localizedDescription)", error: true)
            return "Couldn't send: \(error.localizedDescription)"
        }
    }

    private func fail(_ limit: SessionPace.Limit, _ reason: String) {
        lastFailure[limit] = Date()
        Self.log("Pace notification (\(limit.rawValue)) not shown: \(reason)", error: true)
    }

    private static func log(_ message: String, error: Bool = false) {
        // The in-app debug log only keeps the last 50 lines in memory; the system log outlasts it.
        if error {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        DebugLog.shared.log(message)
    }

    /// The reported reset time drifts by seconds between polls, while windows sit 5 hours apart,
    /// so any reset within 10 minutes of the last alerted one is the same window.
    nonisolated static func sameWindow(_ lastReset: Double?, _ resetsAt: Date) -> Bool {
        guard let lastReset else { return false }
        return abs(resetsAt.timeIntervalSince1970 - lastReset) < 600
    }

    nonisolated static func shouldRetry(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= retryInterval
    }

    // Show the banner even while the popover (our only window) is key.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen() }
        completionHandler()
    }
}
