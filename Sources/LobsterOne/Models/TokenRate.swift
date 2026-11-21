import Foundation

/// Tokens per minute, worked out from how much today's token count grew between two polls.
///
/// The backend's own `burn_rate.tokens_per_minute` is not used for this: it counts cached
/// tokens (which the headline count leaves out) and can span two hourly buckets, so it reads
/// several times higher than the number shown next to it.
struct TokenRate {
    /// Two polls closer than this are treated as one, so a manual refresh right after a
    /// scheduled poll does not produce a spike or a false zero.
    static let minimumGap: TimeInterval = 20
    /// Beyond this the Mac was asleep or offline, and an average over the gap says nothing
    /// about now.
    static let maximumGap: TimeInterval = 30 * 60

    private var last: (tokens: Int, at: Date)?
    private(set) var perMinute: Double = 0

    /// Feed it each successful poll's token count. Returns the current rate.
    mutating func record(tokens: Int, at now: Date = Date()) -> Double {
        guard let previous = last else {
            last = (tokens, now)
            return perMinute
        }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= Self.minimumGap else { return perMinute }

        // A lower count means the day rolled over; there is no growth to measure yet.
        if tokens < previous.tokens || elapsed > Self.maximumGap {
            perMinute = 0
        } else {
            perMinute = Double(tokens - previous.tokens) / elapsed * 60
        }
        last = (tokens, now)
        return perMinute
    }
}
