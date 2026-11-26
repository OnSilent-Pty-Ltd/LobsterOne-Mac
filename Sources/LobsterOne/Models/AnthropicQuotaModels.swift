import Foundation

// MARK: - Anthropic OAuth Usage API Response

struct AnthropicUsageResponse: Decodable {
    let fiveHour: UtilizationWindow?
    let sevenDay: UtilizationWindow?
    let sevenDaySonnet: UtilizationWindow?
    let sevenDayOpus: UtilizationWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

struct UtilizationWindow: Decodable, Equatable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Decodable, Equatable {
    let isEnabled: Bool
    let usedCredits: Double?
    /// Null when the account has no extra-usage cap — must stay optional or
    /// the entire quota response fails to decode (falls back to P90).
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }
}

// MARK: - Claude Code Credentials File (~/.claude/.credentials.json)

struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials?
}

struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Int64
    let subscriptionType: String?
    let rateLimitTier: String?

    var isExpired: Bool {
        Date() >= Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
    }

    /// True if expired or within 5 minutes of expiry — triggers a re-read from source.
    var isExpiredOrExpiringSoon: Bool {
        let expiryDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
        return Date().addingTimeInterval(5 * 60) >= expiryDate
    }

    /// "valid for 7h 12m" or "expired 1d 9h ago", for the debug log.
    func expiryDescription(now: Date = Date()) -> String {
        let expiry = Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
        let gap = expiry.timeIntervalSince(now)
        let span = Self.span(abs(gap))
        return gap > 0 ? "valid for \(span)" : "expired \(span) ago"
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - Published State for UI

struct AnthropicQuotaState: Equatable {
    enum Source: Equatable {
        case oauthAPI
        case webCookies
        case robocogP90
        case none
    }

    var source: Source = .none
    var fiveHourPct: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPct: Double?
    var sevenDayResetsAt: Date?
    var sonnetPct: Double?
    var opusPct: Double?
    var extraUsageEnabled: Bool = false
    var usedCredits: Double?
    var monthlyLimit: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var lastUpdated: Date = .distantPast

    var primaryPct: Double {
        fiveHourPct ?? 0
    }

    /// Human-readable plan label derived from subscriptionType + rateLimitTier
    var planLabel: String? {
        guard let sub = subscriptionType else { return nil }
        let base: String
        switch sub {
        case "claude_pro", "claude_pro_annual": base = "Pro"
        case "claude_max": base = "Max"
        case "claude_team": base = "Team"
        case "claude_enterprise": base = "Enterprise"
        default:
            // Handle "claude_max_5x" style
            if sub.contains("max_5x") || sub.contains("max5") { base = "Max" }
            else if sub.contains("max_20x") || sub.contains("max20") { base = "Max" }
            else { base = sub.replacingOccurrences(of: "claude_", with: "").capitalized }
        }
        // Append tier suffix (e.g., "5x" from "tier_5x")
        if let tier = rateLimitTier {
            if let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
                return "\(base) \(tier[match].uppercased())"
            }
        }
        return base
    }

    static let empty = AnthropicQuotaState()
}

// MARK: - Quota Snapshot Payload (sent to backend)

struct QuotaSnapshotPayload: Encodable {
    let fiveHourPct: Double?
    let fiveHourResetsAt: String?
    let sevenDayPct: Double?
    let sevenDayResetsAt: String?
    let sonnetPct: Double?
    let opusPct: Double?
    let extraCreditsUsed: Double?
    let monthlyLimit: Double?
    let subscriptionType: String?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case fiveHourPct = "five_hour_pct"
        case fiveHourResetsAt = "five_hour_resets_at"
        case sevenDayPct = "seven_day_pct"
        case sevenDayResetsAt = "seven_day_resets_at"
        case sonnetPct = "sonnet_pct"
        case opusPct = "opus_pct"
        case extraCreditsUsed = "extra_credits_used"
        case monthlyLimit = "monthly_limit"
        case subscriptionType = "subscription_type"
        case rateLimitTier = "rate_limit_tier"
    }
}
