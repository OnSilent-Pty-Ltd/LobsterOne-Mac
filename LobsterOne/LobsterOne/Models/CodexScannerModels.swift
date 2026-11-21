import Foundation

// MARK: - Scanner Cache (persisted to disk)

struct CodexScannerCache: Codable {
    var lastScanUnixMs: Int64 = 0
    var files: [String: CodexFileState] = [:]
}

struct CodexFileState: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    var sessionId: String?
    var lastModel: String?
    var lastTotals: TokenTotals?
    var lastRateLimits: CodexRateLimits?
    var lastRateLimitsTimestamp: String?
    /// session_meta.history_mode. "paginated" sessions record applied edits as
    /// item_completed FileChange items; older ("legacy") ones only as apply_patch calls.
    var historyMode: String?
}

struct TokenTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int

    func delta(from previous: TokenTotals?) -> TokenTotals {
        guard let previous else { return self }
        return TokenTotals(
            input: max(0, input - previous.input),
            cached: max(0, cached - previous.cached),
            output: max(0, output - previous.output)
        )
    }

    var isZero: Bool {
        input == 0 && cached == 0 && output == 0
    }
}

// MARK: - Codex Rate Limits (real OpenAI usage, from token_count lines)

struct CodexRateWindow: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Int            // unix epoch seconds
}

struct CodexRateLimits: Codable, Equatable {
    let primary: CodexRateWindow?
    let secondary: CodexRateWindow?
    let planType: String?
}

// MARK: - Parsed JSONL Events

enum CodexJSONLEvent: Equatable {
    case sessionMeta(sessionId: String, historyMode: String?)
    case turnContext(model: String)
    case tokenCount(timestamp: String, totals: TokenTotals)
    case rateLimits(timestamp: String, limits: CodexRateLimits)
    // A completed apply_patch tool call, with lines added/removed counted from the patch body.
    case patchApplied(timestamp: String, added: Int, removed: Int)
    // A completed FileChange item (paginated sessions), counted from the applied diffs.
    // Covers patches made inside code-mode `exec` scripts, which never appear as apply_patch calls.
    case fileChangeApplied(timestamp: String, added: Int, removed: Int)
}

// MARK: - Token Event (ready to forward)

struct TokenEvent {
    let timestamp: String
    let model: String
    let sessionId: String
    let delta: TokenTotals
}

// MARK: - Line Event (ready to forward)

/// One completed apply_patch, attributed to a session/model. Codex emits no
/// lines-of-code metric of its own, so we derive it from the patch body.
struct LineEvent {
    let timestamp: String
    let model: String
    let sessionId: String
    let added: Int
    let removed: Int
}

/// Result of parsing one session file's new bytes: token deltas + line deltas.
struct CodexParseResult {
    var tokens: [TokenEvent] = []
    var lines: [LineEvent] = []
}

// MARK: - JSONL Parser

enum CodexJSONLParser {
    static func parseLine(_ data: Data) -> CodexJSONLEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }

        switch type {
        case "session_meta":
            guard let payload = obj["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String else { return nil }
            return .sessionMeta(sessionId: sessionId, historyMode: payload["history_mode"] as? String)

        case "turn_context":
            guard let payload = obj["payload"] as? [String: Any],
                  let model = payload["model"] as? String else { return nil }
            return .turnContext(model: model)

        case "event_msg":
            guard let timestamp = obj["timestamp"] as? String,
                  let payload = obj["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                return nil
            }
            if payloadType == "item_completed" {
                return parseFileChange(payload, timestamp: timestamp)
            }
            guard payloadType == "token_count" else { return nil }
            // Usage lines carry info.total_token_usage.
            if let info = payload["info"] as? [String: Any],
               let usage = info["total_token_usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let cached = usage["cached_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                return .tokenCount(
                    timestamp: timestamp,
                    totals: TokenTotals(input: input, cached: cached, output: output)
                )
            }
            // Rate-limit lines carry payload.rate_limits (info is typically null).
            if let rl = payload["rate_limits"] as? [String: Any],
               let limits = Self.parseRateLimits(rl) {
                return .rateLimits(timestamp: timestamp, limits: limits)
            }
            return nil

        case "response_item":
            // Codex applies file edits via a custom_tool_call named "apply_patch".
            // The patch body lives in `input` (V4A format). Count only completed ones.
            guard let timestamp = obj["timestamp"] as? String,
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "custom_tool_call",
                  payload["name"] as? String == "apply_patch",
                  payload["status"] as? String == "completed",
                  let input = payload["input"] as? String else {
                return nil
            }
            let counts = countPatchLines(input)
            guard counts.added > 0 || counts.removed > 0 else { return nil }
            return .patchApplied(timestamp: timestamp, added: counts.added, removed: counts.removed)

        default:
            return nil
        }
    }

    /// item_completed payload whose item is a completed FileChange:
    /// `changes` maps each path to `{type: add|delete, content}` or `{type: update, unified_diff}`.
    static func parseFileChange(_ payload: [String: Any], timestamp: String) -> CodexJSONLEvent? {
        guard let item = payload["item"] as? [String: Any],
              item["type"] as? String == "FileChange",
              item["status"] as? String == "completed",
              let changes = item["changes"] as? [String: Any] else {
            return nil
        }
        var added = 0
        var removed = 0
        for case let change as [String: Any] in changes.values {
            switch change["type"] as? String {
            case "add":
                added += countContentLines(change["content"] as? String ?? "")
            case "delete":
                removed += countContentLines(change["content"] as? String ?? "")
            case "update":
                let counts = countPatchLines(change["unified_diff"] as? String ?? "")
                added += counts.added
                removed += counts.removed
            default:
                continue
            }
        }
        guard added > 0 || removed > 0 else { return nil }
        return .fileChangeApplied(timestamp: timestamp, added: added, removed: removed)
    }

    /// Lines in a whole added/deleted file (a trailing newline does not start a new line).
    static func countContentLines(_ content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return content.hasSuffix("\n") ? lines.count - 1 : lines.count
    }

    /// Count added/removed lines in a Codex V4A apply_patch body. V4A uses
    /// `+`/`-`/` ` line prefixes under `*** Update/Add/Delete File` sections and
    /// `@@` hunk markers (none of which start with `+`/`-`). The `+++ `/`--- `
    /// guards are defensive against unified-diff-style headers. FileChange
    /// unified diffs use the same `+`/`-` prefixes, so they are counted here too.
    static func countPatchLines(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 }
            else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    static func parseRateLimits(_ obj: [String: Any]) -> CodexRateLimits? {
        func window(_ key: String) -> CodexRateWindow? {
            guard let w = obj[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let mins = (w["window_minutes"] as? NSNumber)?.int64Value,
                  let resets = (w["resets_at"] as? NSNumber)?.int64Value else { return nil }
            return CodexRateWindow(usedPercent: pct, windowMinutes: Int(mins), resetsAt: Int(resets))
        }
        let primary = window("primary")
        let secondary = window("secondary")
        let planType = obj["plan_type"] as? String
        // Only a rate-limit event if at least one window is present.
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateLimits(primary: primary, secondary: secondary, planType: planType)
    }
}

// MARK: - Codex Quota Snapshot Payload (sent to backend)

struct CodexQuotaSnapshotPayload: Encodable {
    let provider = "codex"
    let codexPrimaryPct: Double?
    let codexPrimaryResetsAt: String?      // ISO-8601
    let codexSecondaryPct: Double?
    let codexSecondaryResetsAt: String?    // ISO-8601
    let codexPlanType: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case codexPrimaryPct = "codex_primary_pct"
        case codexPrimaryResetsAt = "codex_primary_resets_at"
        case codexSecondaryPct = "codex_secondary_pct"
        case codexSecondaryResetsAt = "codex_secondary_resets_at"
        case codexPlanType = "codex_plan_type"
    }

    /// Build from parsed rate limits, converting epoch-second reset times to ISO-8601.
    init(from limits: CodexRateLimits) {
        codexPrimaryPct = limits.primary?.usedPercent
        codexPrimaryResetsAt = limits.primary.map { Self.iso(epochSeconds: $0.resetsAt) }
        codexSecondaryPct = limits.secondary?.usedPercent
        codexSecondaryResetsAt = limits.secondary.map { Self.iso(epochSeconds: $0.resetsAt) }
        codexPlanType = limits.planType
    }

    private static func iso(epochSeconds: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }
}

// MARK: - OTel Payload Builder

enum OTelPayloadBuilder {
    static func buildMetricsPayload(events: [TokenEvent], lineEvents: [LineEvent] = []) -> [String: Any] {
        // Filter out zero-delta events
        let nonZero = events.filter { !$0.delta.isZero }

        // Group by sessionId
        let grouped = Dictionary(grouping: nonZero, by: \.sessionId)

        var resourceMetrics: [[String: Any]] = grouped.map { sessionId, sessionEvents in
            let dataPoints: [[String: Any]] = sessionEvents.flatMap { event -> [[String: Any]] in
                let nanos = isoToNanos(event.timestamp)
                var points: [[String: Any]] = []
                // Codex input_tokens includes cached — subtract to get non-cached input
                let nonCachedInput = max(0, event.delta.input - event.delta.cached)
                let types: [(String, Int)] = [
                    ("input", nonCachedInput),
                    ("cacheRead", event.delta.cached),
                    ("output", event.delta.output),
                ]
                for (tokenType, value) in types where value > 0 {
                    points.append([
                        "attributes": [
                            otelAttr("type", tokenType),
                            otelAttr("model", event.model),
                        ],
                        "timeUnixNano": nanos,
                        "asInt": String(value),
                    ])
                }
                return points
            }

            return [
                "resource": [
                    "attributes": [
                        otelAttr("service.name", "codex"),
                        otelAttr("session.id", sessionId),
                    ]
                ],
                "scopeMetrics": [[
                    "scope": ["name": "lobsterone.mac"],
                    "metrics": [[
                        "name": "codex.token.usage",
                        "sum": [
                            "aggregationTemporality": 2,
                            "isMonotonic": true,
                            "dataPoints": dataPoints,
                        ] as [String: Any],
                    ] as [String: Any]],
                ] as [String: Any]],
            ]
        }

        // Lines of code: derived per-patch deltas, grouped by session. Emitted as a
        // separate resourceMetrics block with metric_type added/removed data points.
        // codex.lines_of_code.count is a delta metric server-side, so values are summed.
        let linesBySession = Dictionary(grouping: lineEvents, by: \.sessionId)
        for (sessionId, sessionLines) in linesBySession {
            let dataPoints: [[String: Any]] = sessionLines.flatMap { event -> [[String: Any]] in
                let nanos = isoToNanos(event.timestamp)
                let types: [(String, Int)] = [("added", event.added), ("removed", event.removed)]
                return types.compactMap { lineType, value in
                    guard value > 0 else { return nil }
                    return [
                        "attributes": [
                            otelAttr("type", lineType),
                            otelAttr("model", event.model),
                        ],
                        "timeUnixNano": nanos,
                        "asInt": String(value),
                    ]
                }
            }
            guard !dataPoints.isEmpty else { continue }
            resourceMetrics.append([
                "resource": [
                    "attributes": [
                        otelAttr("service.name", "codex"),
                        otelAttr("session.id", sessionId),
                    ]
                ],
                "scopeMetrics": [[
                    "scope": ["name": "lobsterone.mac"],
                    "metrics": [[
                        "name": "codex.lines_of_code.count",
                        "sum": [
                            "aggregationTemporality": 1,  // DELTA: each point is one patch's line count
                            "isMonotonic": true,
                            "dataPoints": dataPoints,
                        ] as [String: Any],
                    ] as [String: Any]],
                ] as [String: Any]],
            ])
        }

        return ["resourceMetrics": resourceMetrics]
    }

    private static func otelAttr(_ key: String, _ value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoToNanos(_ iso: String) -> String {
        if let date = isoFormatterFractional.date(from: iso) {
            return String(Int64(date.timeIntervalSince1970 * 1_000_000_000))
        }
        if let date = isoFormatterBasic.date(from: iso) {
            return String(Int64(date.timeIntervalSince1970 * 1_000_000_000))
        }
        return "0"
    }
}
