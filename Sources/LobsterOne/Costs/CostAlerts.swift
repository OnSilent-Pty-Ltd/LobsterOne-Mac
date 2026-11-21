import Foundation

/// Shows a Mac notification. Abstracted so the alert rules can be tested.
@MainActor
protocol AlertNotifying {
    /// False while the person has cost alerts switched off. Nothing is marked as sent then,
    /// so an alert that came due in the meantime still fires once they switch them back on.
    var isEnabled: Bool { get }
    func requestPermission()
    func notify(id: String, title: String, body: String)
}

/// Per-account spend alerts: "tell me when this account passes $X this month".
/// Stored locally; nothing is created in AWS.
nonisolated struct CostAlertStore {
    let defaults: UserDefaults
    private static let limitsKey = "awsCostAlertLimits"
    private static let notifiedKey = "awsCostAlertNotified"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Subject id (`AccountCost.id`) to monthly alert amount.
    var limits: [String: Double] {
        (defaults.dictionary(forKey: Self.limitsKey) as? [String: Double]) ?? [:]
    }

    func setLimit(_ amount: Double?, for id: String) {
        var all = limits
        all[id] = amount
        defaults.set(all, forKey: Self.limitsKey)
        // A changed amount may deserve a fresh alert this month.
        var sent = notified
        sent.removeValue(forKey: id)
        defaults.set(sent, forKey: Self.notifiedKey)
    }

    /// Subject id to the "YYYY-MM" month it was last alerted for.
    private var notified: [String: String] {
        (defaults.dictionary(forKey: Self.notifiedKey) as? [String: String]) ?? [:]
    }

    func wasNotified(_ id: String, month: String) -> Bool { notified[id] == month }

    func markNotified(_ id: String, month: String) {
        var sent = notified
        sent[id] = month
        defaults.set(sent, forKey: Self.notifiedKey)
    }
}

nonisolated enum CostAlerts {
    /// Reads a typed amount like "20", "$20" or "12,50". Nil when empty or not
    /// a positive number.
    static func parseAmount(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }
        return Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Something an alert can watch. Today that's an AWS account.
    struct Subject: Equatable, Sendable {
        let id: String
        let name: String
        let thisMonth: Double
    }

    /// Subjects over their amount this month that haven't been alerted yet.
    static func due(_ subjects: [Subject], store: CostAlertStore, month: String) -> [(subject: Subject, limit: Double)] {
        let limits = store.limits
        return subjects.compactMap { s in
            guard let limit = limits[s.id], s.thisMonth > limit,
                  !store.wasNotified(s.id, month: month) else { return nil }
            return (s, limit)
        }
    }
}
