import AppKit

struct QuotaState: Equatable {
    var usedTokens: Int
    var usedRequests: Int
    var limitRequests: Int
    var planTier: String
    var percentUsed: Double
    var lastUpdated: Date
    var isOffline: Bool
    var offlineReason: String
    var hasQuota: Bool
    var isRealQuota: Bool = false
    var anthropicState: AnthropicQuotaState? = nil
    /// Growth in `usedTokens` between polls (see `TokenRate`). Drives the screensaver's animation.
    var tokensPerMinute: Double = 0

    private static let tierLabels: [String: String] = [
        "pro": "Pro",
        "max5": "Max 5x",
        "max20": "Max 20x",
        "team": "Team",
        "team_premium": "Team Premium",
        "enterprise": "Enterprise",
    ]

    static func tierLabel(for tier: String) -> String {
        tierLabels[tier] ?? tier.capitalized
    }

    var displayPlanTier: String {
        Self.tierLabel(for: planTier)
    }

    var formattedTokens: String {
        if usedTokens >= 1_000_000 {
            let millions = Double(usedTokens) / 1_000_000.0
            if millions == millions.rounded(.down) {
                return "\(Int(millions))M"
            }
            // 3 decimals so daily evolution stays visible past 1M (e.g. "1.043M").
            return String(format: "%.3fM", millions)
        } else if usedTokens >= 999_500 {
            // Would round to 1000K, show as 1M instead
            return "1M"
        } else if usedTokens >= 1_000 {
            let thousands = Double(usedTokens) / 1_000.0
            if thousands == thousands.rounded(.down) {
                return "\(Int(thousands))K"
            }
            return String(format: "%.0fK", thousands)
        }
        return "\(usedTokens)"
    }

    var formattedPercent: String {
        let prefix = isRealQuota ? "" : "~"
        return "\(prefix)\(Int(percentUsed.rounded()))%"
    }

    var menuBarText: String {
        if isOffline {
            return "\(formattedTokens) / offline"
        }
        return formattedTokens
    }

    enum StatusLevel {
        case ok, warning, critical, offline

        var nsColor: NSColor {
            switch self {
            case .ok: .systemGreen
            case .warning: .systemYellow
            case .critical: .systemRed
            case .offline: .systemGray
            }
        }
    }

    var statusLevel: StatusLevel {
        if isOffline { return .offline }
        if percentUsed >= 80 { return .critical }
        if percentUsed >= 50 { return .warning }
        return .ok
    }

    static let empty = QuotaState(
        usedTokens: 0, usedRequests: 0, limitRequests: 0,
        planTier: "", percentUsed: 0, lastUpdated: Date(),
        isOffline: true, offlineReason: "", hasQuota: true,
        isRealQuota: false, anthropicState: nil
    )
}
