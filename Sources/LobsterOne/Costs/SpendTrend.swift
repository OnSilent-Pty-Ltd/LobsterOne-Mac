import Foundation

/// How one line of spend compares with last month: the numbers behind its
/// progress bar and trend badge in the menu.
nonisolated struct SpendTrend: Equatable, Sendable {
    let thisMonth: Double
    let lastMonth: Double
    let forecast: Double?

    /// On pace to finish more than 20% above last month.
    var isRising: Bool {
        guard let forecast else { return false }
        return lastMonth > 0 && forecast > lastMonth * 1.2
    }

    /// Projected change against last month (-0.18 is 18% lower). Nil without
    /// both a forecast and a last month to compare with.
    var change: Double? {
        guard let forecast, lastMonth > 0 else { return nil }
        return forecast / lastMonth - 1
    }

    /// The bar's full width stands for the largest of the three figures, so
    /// it normally ends at last month's total and stretches when this month
    /// is heading past it.
    private var scale: Double { max(lastMonth, forecast ?? 0, thisMonth) }

    var spentFraction: Double { scale > 0 ? thisMonth / scale : 0 }
    var paceFraction: Double { scale > 0 ? (forecast ?? thisMonth) / scale : 0 }

    /// Average spend per day so far, read back from the straight-line forecast.
    func dailyAverage(daysInMonth: Int) -> Double? {
        guard let forecast, daysInMonth > 0 else { return nil }
        return forecast / Double(daysInMonth)
    }

    /// Where last month's total sits along the bar, when this month is
    /// heading past it. Nil when last month is the end of the bar.
    var lastMonthMark: Double? {
        guard lastMonth > 0, scale > lastMonth else { return nil }
        return lastMonth / scale
    }
}

extension CostMath {
    /// How many days a "YYYY-MM" month has.
    nonisolated static func days(inMonth month: String) -> Int? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let first = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return nil }
        return utc.range(of: .day, in: .month, for: first)?.count
    }
}
