import AppKit
import UserNotifications

/// Banners for invites into the harbour town, from the poll and from Apple push alike.
/// Both use the identifier `town-<invite_id>` (the push sets it as apns-collapse-id), so one
/// invite is one banner whichever path saw it first. Owns the notification centre delegate and
/// hands everything that isn't a town invite to `PaceNotifier`, which keeps today's behaviour.
@MainActor
final class TownInviteNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "townInvitesEnabled"
    private static let ledgerKey = "townInvites.ledger"
    static let threadId = "town"
    static let categoryId = "TOWN_INVITE"

    private let defaults: UserDefaults
    private let pace: PaceNotifier
    /// Opens the town in the default browser; replaceable for tests.
    var onOpen: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(pace: PaceNotifier, defaults: UserDefaults = .standard) {
        self.pace = pace
        self.defaults = defaults
        super.init()
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// UNUserNotificationCenter traps when the process has no bundle (e.g. `swift run`).
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// Take over the delegate from PaceNotifier (it is still called for its own notifications).
    func install() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Several invites stack under one thread: "3 people want to chat in town".
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: nil,
                                   categorySummaryFormat: "%u people want to chat in town",
                                   options: []),
            // Categories are set as one list, so the crew's reminder buttons are registered here too.
            CrewJobNotifier.category,
        ])
    }

    // MARK: - Poll path

    /// Call with every invite list the count call returns.
    func update(_ invites: [TownInvite]) {
        guard hasBundle else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await deliveredInviteIds(center)
            var ledger = loadLedger()
            let plan = ledger.plan(invites: invites, delivered: delivered, enabled: Self.isEnabled, now: Date())
            saveLedger(ledger)

            if !plan.remove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: plan.remove.map(TownInvite.notificationId))
            }
            for invite in plan.post {
                await post(invite, center: center)
            }
        }
    }

    private func post(_ invite: TownInvite, center: UNUserNotificationCenter) async {
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
            let content = UNMutableNotificationContent()
            content.title = invite.notificationTitle
            content.body = invite.notificationBody
            content.sound = .default
            content.threadIdentifier = Self.threadId
            content.categoryIdentifier = Self.categoryId
            content.userInfo = ["invite_id": invite.inviteId]
            let id = TownInvite.notificationId(invite.inviteId)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            DebugLog.shared.log("Town invite banner posted")
        } catch {
            DebugLog.shared.log("Town invite notification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Push path

    /// An alert push for this invite reached the running app. Hides it when it falls in quiet
    /// hours, over the daily cap or with the switch off. Returns whether it may show.
    @discardableResult
    func admitPush(inviteId: String) -> Bool {
        var ledger = loadLedger()
        let keep = ledger.admitPush(inviteId: inviteId, enabled: Self.isEnabled, now: Date())
        saveLedger(ledger)
        if !keep { remove(inviteIds: [inviteId]) }
        return keep
    }

    /// The background `town_clear` push, the Join button and the switch going off.
    func remove(inviteIds: [String]) {
        guard hasBundle, !inviteIds.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: inviteIds.map(TownInvite.notificationId))
    }

    func removeAll() {
        guard hasBundle else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await deliveredInviteIds(center)
            remove(inviteIds: Array(ids))
        }
    }

    func open(inviteId: String) {
        remove(inviteIds: [inviteId])
        if let url = TownInvite.joinURL(inviteId: inviteId) { onOpen(url) }
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let inviteId = Self.inviteId(of: notification) else {
            pace.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
            return
        }
        // Local banners were already checked against the rules before posting.
        guard notification.request.trigger is UNPushNotificationTrigger else {
            completionHandler([.banner, .sound])
            return
        }
        Task { @MainActor in
            completionHandler(self.admitPush(inviteId: inviteId) ? [.banner, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if CrewJobNotifier.handle(response) {
            completionHandler()
            return
        }
        guard let inviteId = Self.inviteId(of: response.notification) else {
            pace.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }
        Task { @MainActor in self.open(inviteId: inviteId) }
        completionHandler()
    }

    /// From the identifier, or from the push's custom `invite_id` if the identifier differs.
    nonisolated private static func inviteId(of notification: UNNotification) -> String? {
        if let id = TownInvite.inviteId(fromNotificationId: notification.request.identifier) { return id }
        if let id = notification.request.content.userInfo["invite_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    // MARK: - Storage

    private func deliveredInviteIds(_ center: UNUserNotificationCenter) async -> Set<String> {
        let delivered = await center.deliveredNotifications()
        return Set(delivered.compactMap { TownInvite.inviteId(fromNotificationId: $0.request.identifier) })
    }

    private func loadLedger() -> TownInviteLedger {
        guard let data = defaults.data(forKey: Self.ledgerKey),
              let ledger = try? JSONDecoder().decode(TownInviteLedger.self, from: data) else { return TownInviteLedger() }
        return ledger
    }

    private func saveLedger(_ ledger: TownInviteLedger) {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}
