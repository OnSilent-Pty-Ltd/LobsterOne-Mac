import Foundation

/// Linear projection of a Claude usage window (the 5-hour session or the 7-day week): if usage
/// keeps its average rate since the window opened, does it hit 100% before the window resets?
enum SessionPace {
    enum Limit: String {
        case session, week

        var window: TimeInterval { self == .session ? 5 * 3600 : 7 * 24 * 3600 }
        /// Too early in a window a single burst projects wildly, so stay quiet until this much has elapsed.
        var minimumElapsed: TimeInterval { self == .session ? 15 * 60 : 24 * 3600 }
    }

    /// A projected lockout shorter than this is within the projection's noise, and would read as
    /// "locked out 0m before the session resets", so it doesn't warn.
    static let minimumLockout: TimeInterval = 5 * 60

    struct Warning: Equatable {
        let minutesToCap: Int
        let minutesCappedBeforeReset: Int
    }

    static func warning(percent: Double, resetsAt: Date, now: Date = Date(), limit: Limit = .session) -> Warning? {
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = limit.window - remaining
        guard percent > 0, percent < 100, remaining > 0, elapsed >= limit.minimumElapsed else { return nil }

        let ratePerSecond = percent / elapsed
        let secondsToCap = (100 - percent) / ratePerSecond
        guard remaining - secondsToCap >= minimumLockout else { return nil }

        return Warning(
            minutesToCap: max(1, Int((secondsToCap / 60).rounded())),
            minutesCappedBeforeReset: Int(((remaining - secondsToCap) / 60).rounded())
        )
    }
}
