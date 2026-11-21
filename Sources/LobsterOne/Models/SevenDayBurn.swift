import Foundation

/// One day bucket of usage, as returned in `/v1/usage/status` → `realtime.seven_day`.
struct DailyUsage: Decodable {
    let date: String        // "yyyy-MM-dd"
    let inputTokens: Int
    let outputTokens: Int
    let costUsd: Double

    enum CodingKeys: String, CodingKey {
        case date
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
    }

    init(date: String, inputTokens: Int, outputTokens: Int, costUsd: Double) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUsd = costUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        costUsd = (try? c.decode(Double.self, forKey: .costUsd)) ?? 0
    }
}

/// Aggregated 7-day burn for the menu dropdown.
struct SevenDayBurn: Equatable {
    let bars: [Int]        // per-day input+output, oldest -> newest, as ordered by the server
    let totalTokens: Int
    let costUsd: Double
    var days: [Day] = []   // same order as `bars`, carrying the server's date and cost per bucket

    struct Day: Equatable {
        let date: String   // "yyyy-MM-dd" exactly as the server labelled the bucket
        let tokens: Int
        let costUsd: Double

        /// The bucket's date as a calendar day. Parsed and formatted in UTC so the label
        /// always names the server's bucket, never a timezone-shifted neighbour.
        private var parsed: Date? { Self.parser.date(from: date) }

        /// "M", "T", ... for the bar axis.
        var weekdayInitial: String { parsed.map { String(Self.weekday.string(from: $0).prefix(1)) } ?? "" }

        /// "Wed 11 Nov" for hover detail. Falls back to the raw string if unparseable.
        var longLabel: String { parsed.map { Self.long.string(from: $0) } ?? date }

        /// True when the server bucket is the same calendar date as the user's local today.
        func isToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
            let c = calendar.dateComponents([.year, .month, .day], from: now)
            return date == String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        private static func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
        private static let parser = formatter("yyyy-MM-dd")
        private static let weekday = formatter("EEE")
        private static let long = formatter("EEE d MMM")
    }

    /// Build from the server's pre-ordered, zero-filled daily buckets. The server owns the
    /// date axis (UTC, oldest -> newest), so we render the buckets in order without any
    /// client-side date math — avoiding timezone drift between client and server.
    static func from(_ buckets: [DailyUsage]) -> SevenDayBurn {
        let bars = buckets.map { max(0, $0.inputTokens) + max(0, $0.outputTokens) }
        let total = bars.reduce(0, +)
        let cost = buckets.reduce(0.0) { $0 + $1.costUsd }
        let days = zip(buckets, bars).map { Day(date: $0.date, tokens: $1, costUsd: $0.costUsd) }
        return SevenDayBurn(bars: bars, totalTokens: total, costUsd: cost, days: days)
    }

    var formattedTotalTokens: String { Self.formatTokens(totalTokens) }

    /// Abbreviate a token count: 1_240_000 -> "1.2M", 12_400 -> "12K", 450 -> "450".
    static func formatTokens(_ value: Int) -> String {
        // Token counts stay well under 1B in practice, so no B-suffix is needed.
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            return m == m.rounded(.down) ? "\(Int(m))M" : String(format: "%.1fM", m)
        } else if value >= 1_000 {
            let k = Double(value) / 1_000.0
            return k == k.rounded(.down) ? "\(Int(k))K" : String(format: "%.0fK", k)
        }
        return "\(value)"
    }
}
