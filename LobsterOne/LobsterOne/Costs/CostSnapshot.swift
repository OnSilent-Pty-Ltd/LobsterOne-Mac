import Foundation

// The cost types are pure values, marked `nonisolated` so the Xcode build (default MainActor
// isolation) can still use them from the AWS client off the main actor.

/// One Cost Explorer reading: spend per AWS account for last month and this
/// month so far. Cached on disk so opening the menu never has to pay for a call.
nonisolated struct CostSnapshot: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let currency: String
    /// The UTC month this snapshot's `thisMonth` covers, as "YYYY-MM".
    let month: String
    let thisMonth: [String: Double]
    let lastMonth: [String: Double]
    /// AWS marks the current month as estimated until the bill is final.
    let estimated: Bool
    /// Account id to its name in AWS Organizations, when readable. Optional so
    /// caches written before names were fetched still load.
    var accountNames: [String: String]? = nil

    var thisMonthTotal: Double { thisMonth.values.reduce(0, +) }
    var lastMonthTotal: Double { lastMonth.values.reduce(0, +) }
}

/// One AWS account's spend this month and last.
nonisolated struct AccountCost: Equatable, Identifiable, Sendable {
    let accountId: String
    let name: String?
    let thisMonth: Double
    let lastMonth: Double
    let forecast: Double?

    /// Alert key. Prefixed so it can't collide with any other kind of alert subject later.
    var id: String { "account:\(accountId)" }
    var displayName: String { name ?? "Account \(accountId)" }
}

nonisolated enum CostMath {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// "YYYY-MM-DD" in UTC, the format Cost Explorer expects.
    static func day(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func month(_ date: Date) -> String { String(day(date).prefix(7)) }

    /// Start of last month through the start of next month, so one request
    /// returns both months. The end is exclusive.
    static func window(now: Date) -> (start: String, end: String) {
        let startOfMonth = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        let lastMonth = utc.date(byAdding: .month, value: -1, to: startOfMonth)!
        let nextMonth = utc.date(byAdding: .month, value: 1, to: startOfMonth)!
        return (day(lastMonth), day(nextMonth))
    }

    /// Straight-line end-of-month estimate from completed days. Nil in the
    /// first few days, when there's too little to go on.
    static func forecast(monthToDate: Double, now: Date) -> Double? {
        let dayOfMonth = utc.component(.day, from: now)
        let completed = dayOfMonth - 1
        guard completed >= 3, let days = utc.range(of: .day, in: .month, for: now)?.count else { return nil }
        return monthToDate / Double(completed) * Double(days)
    }

    /// Every account with spend this month or last, biggest spenders first.
    /// `fallbackNames` names accounts AWS Organizations didn't: only the management account
    /// may list names, so a member login would otherwise show bare account numbers.
    static func accounts(snapshot: CostSnapshot?, now: Date, fallbackNames: [String: String] = [:]) -> [AccountCost] {
        // A snapshot from an earlier month says nothing about this month.
        guard let snapshot, snapshot.month == month(now) else { return [] }
        let ids = Set(snapshot.thisMonth.keys).union(snapshot.lastMonth.keys)
        return ids.map { id in
            let mtd = snapshot.thisMonth[id] ?? 0
            return AccountCost(accountId: id, name: snapshot.accountNames?[id] ?? fallbackNames[id], thisMonth: mtd,
                               lastMonth: snapshot.lastMonth[id] ?? 0,
                               forecast: forecast(monthToDate: mtd, now: now))
        }
        .sorted { ($0.thisMonth, $0.lastMonth, $1.accountId) > ($1.thisMonth, $1.lastMonth, $0.accountId) }
    }
}
