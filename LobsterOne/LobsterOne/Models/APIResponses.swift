import Foundation

// Response from GET /v1/usage/quota (API key auth)
struct QuotaResponse: Decodable {
    let planTier: String
    let planTierSource: String
    let windowHours: Int
    let limitRequests: Int
    let usedRequests: Int
    let usedTokens: Int
    let percentUsed: Double
    let burnRate: BurnRate
    let nextRecoveryAt: String?
    let anthropicQuota: AnthropicQuotaEnvelope?

    enum CodingKeys: String, CodingKey {
        case planTier = "plan_tier"
        case planTierSource = "plan_tier_source"
        case windowHours = "window_hours"
        case limitRequests = "limit_requests"
        case usedRequests = "used_requests"
        case usedTokens = "used_tokens"
        case percentUsed = "percent_used"
        case burnRate = "burn_rate"
        case nextRecoveryAt = "next_recovery_at"
        case anthropicQuota = "anthropic_quota"
    }

    func toQuotaState() -> QuotaState {
        QuotaState(
            usedTokens: usedTokens,
            usedRequests: usedRequests,
            limitRequests: limitRequests,
            planTier: planTier,
            percentUsed: percentUsed,
            lastUpdated: Date(),
            isOffline: false,
            offlineReason: "",
            hasQuota: true,
            isRealQuota: anthropicQuota != nil,
            anthropicState: anthropicQuota?.toAnthropicQuotaState()
        )
    }
}

/// Real quota data returned by the backend when a fresh quota_snapshot exists.
struct AnthropicQuotaEnvelope: Decodable {
    let fiveHourPct: Double?
    let sevenDayPct: Double?
    let sonnetPct: Double?
    let opusPct: Double?
    let extraCreditsUsed: Double?
    let monthlyLimit: Double?
    let subscriptionType: String?
    let rateLimitTier: String?
    let snapshotAgeSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case fiveHourPct = "five_hour_pct"
        case sevenDayPct = "seven_day_pct"
        case sonnetPct = "sonnet_pct"
        case opusPct = "opus_pct"
        case extraCreditsUsed = "extra_credits_used"
        case monthlyLimit = "monthly_limit"
        case subscriptionType = "subscription_type"
        case rateLimitTier = "rate_limit_tier"
        case snapshotAgeSeconds = "snapshot_age_seconds"
    }

    func toAnthropicQuotaState() -> AnthropicQuotaState {
        var s = AnthropicQuotaState()
        s.source = .oauthAPI
        s.lastUpdated = Date()
        s.fiveHourPct = fiveHourPct
        s.sevenDayPct = sevenDayPct
        s.sonnetPct = sonnetPct
        s.opusPct = opusPct
        s.subscriptionType = subscriptionType
        s.rateLimitTier = rateLimitTier
        if let used = extraCreditsUsed, let limit = monthlyLimit {
            s.extraUsageEnabled = true
            s.usedCredits = used
            s.monthlyLimit = limit
        }
        return s
    }
}

struct BurnRate: Decodable {
    let requestsPerMinute: Double
    let tokensPerMinute: Double
    let minutesUntilLimit: Double?
    let estimatedLimitAt: String?

    enum CodingKeys: String, CodingKey {
        case requestsPerMinute = "requests_per_minute"
        case tokensPerMinute = "tokens_per_minute"
        case minutesUntilLimit = "minutes_until_limit"
        case estimatedLimitAt = "estimated_limit_at"
    }
}

// Response from GET /v1/usage/realtime (API key auth)
struct RealtimeResponse: Decodable {
    let tokens: TokenBreakdown
    let cost_usd: Double
    let sessions: Int
    let lines: LineBreakdown
    let prs: Int
    let commits: Int
    let active_seconds: ActiveSeconds
    let seven_day: [DailyUsage]?
}

struct TokenBreakdown: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int
    let total: Int
}

struct LineBreakdown: Decodable {
    let added: Int
    let removed: Int
    let net: Int
}

struct ActiveSeconds: Decodable {
    let user: Double
    let cli: Double
    let total: Double
}

// Response from GET /v1/usage/status (API key auth) — combined realtime + quota
struct StatusResponse: Decodable {
    let realtime: RealtimeResponse
    let quota: QuotaResponse
    let clientPolicy: ClientPolicy?

    enum CodingKeys: String, CodingKey {
        case realtime
        case quota
        case clientPolicy = "client_policy"
    }
}

// Response from GET /v1/api-keys (JWT auth)
struct Instance: Decodable, Identifiable {
    let id: String
    let keyPrefix: String?
    let label: String?
    let createdAt: String?
    let revokedAt: String?
    let lastSeenAt: String?
    let sourceType: String?
    let orphaned: Bool?

    var displayName: String {
        label ?? keyPrefix ?? id.prefix(8).description
    }

    var isActive: Bool {
        revokedAt == nil && orphaned != true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case keyPrefix = "key_prefix"
        case label
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case lastSeenAt = "last_seen_at"
        case sourceType = "source_type"
        case orphaned
    }
}

struct CreateAPIKeyRequest: Encodable {
    let label: String
    let sourceType: String?

    enum CodingKeys: String, CodingKey {
        case label
        case sourceType = "source_type"
    }
}

struct CreateAPIKeyResponse: Decodable {
    let id: String
    let keyPrefix: String
    let label: String?
    let createdAt: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case id
        case keyPrefix = "key_prefix"
        case label
        case createdAt = "created_at"
        case key
    }
}

struct RevokeAPIKeyResponse: Decodable {
    let revoked: Bool?
    let deleted: Bool?
}

// Response from GET /v1/instance/status (API key auth)
struct InstanceStatusResponse: Decodable {
    let instanceId: String
    let lastSeenAt: String?
    let today: InstanceStatusToday
    let status: String  // "active" | "connected_no_data" | "unknown"
    /// Whether the backend has EVER received an OTEL metric from this
    /// instance. Nil when talking to an older backend. Distinct from
    /// lastSeenAt, which scanner session imports also bump.
    let hasOtelData: Bool?

    enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case lastSeenAt = "last_seen_at"
        case today
        case status
        case hasOtelData = "has_otel_data"
    }
}

struct InstanceStatusToday: Decodable {
    let metricCount: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case metricCount = "metric_count"
        case totalTokens = "total_tokens"
    }
}

// Response from GET /v1/notifications/count (API key auth)
struct NotificationCountResponse: Decodable {
    let unread: Int
    /// Open invites into the harbour town. Nil from backends that predate them, so the app
    /// leaves town banners alone; an invite that fails to decode is skipped, not fatal.
    let townInvites: [TownInvite]?

    enum CodingKeys: String, CodingKey {
        case unread
        case townInvites = "town_invites"
    }

    init(unread: Int, townInvites: [TownInvite]? = nil) {
        self.unread = unread
        self.townInvites = townInvites
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = try c.decode(Int.self, forKey: .unread)
        if let items = try? c.decodeIfPresent([Lossy<TownInvite>].self, forKey: .townInvites) {
            townInvites = items.compactMap(\.value)
        } else {
            townInvites = nil
        }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

// Body of PUT and DELETE /v1/devices/apns (API key auth)
struct APNsDeviceRequest: Encodable {
    let token: String
    let environment: String  // "development" | "production"
    /// IANA zone, so the backend can skip alert pushes in local quiet hours.
    let timeZone: String

    enum CodingKeys: String, CodingKey {
        case token, environment
        case timeZone = "time_zone"
    }
}

struct SourceStatus: Identifiable {
    let id: String           // "claude-code" or "codex"
    let displayName: String
    let keyPrefix: String?
    let lastSeenAt: Date?
    let todayTokens: Int
    let backendStatus: String?
    let isConfigured: Bool
    let percentUsed: Double  // per-instance quota percentage

    enum StatusLevel {
        case active       // green — data received
        case waiting      // yellow — configured, no data
        case disconnected // gray — not configured
    }

    var statusLevel: StatusLevel {
        if !isConfigured { return .disconnected }
        if backendStatus == "connected_no_data" { return .waiting }
        if backendStatus == "active" || todayTokens > 0 { return .active }
        if lastSeenAt != nil { return .waiting }
        return .waiting
    }

    var lastSeenText: String {
        if backendStatus == "connected_no_data" {
            return "Connected, waiting for first parsed data"
        }
        guard let lastSeenAt else {
            if todayTokens > 0 {
                let formatted = todayTokens >= 1_000_000
                    ? String(format: "%.1fM tokens today", Double(todayTokens) / 1_000_000)
                    : todayTokens >= 1_000
                        ? String(format: "%.1fK tokens today", Double(todayTokens) / 1_000)
                        : "\(todayTokens) tokens today"
                return formatted
            }
            return "Waiting for first data"
        }
        let seconds = Int(Date().timeIntervalSince(lastSeenAt))
        if seconds < 60 { return "Last seen just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Last seen \(minutes)m ago" }
        let hours = minutes / 60
        return "Last seen \(hours)h ago"
    }
}
