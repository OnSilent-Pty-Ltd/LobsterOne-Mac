import Foundation

/// Parsed cumulative stats for one Vibe session (from meta.json).
struct VibeSessionStats: Equatable {
    let sessionId: String
    let parentSessionId: String?
    let model: String
    let gitBranch: String?
    let promptTokens: Int
    let completionTokens: Int
    let cost: Double
}

/// Parses a Vibe session `meta.json` blob. Uses JSONSerialization (house style,
/// matching CodexJSONLParser) rather than Codable to read nested best-effort fields.
enum VibeMetaParser {
    static func parse(_ data: Data) -> VibeSessionStats? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = obj["session_id"] as? String,
            let stats = obj["stats"] as? [String: Any]
        else { return nil }

        let model = extractModel(obj)
        return VibeSessionStats(
            sessionId: sessionId,
            parentSessionId: obj["parent_session_id"] as? String,
            model: model,
            gitBranch: obj["git_branch"] as? String,
            promptTokens: (stats["session_prompt_tokens"] as? Int) ?? 0,
            completionTokens: (stats["session_completion_tokens"] as? Int) ?? 0,
            cost: (stats["session_cost"] as? Double)
                ?? (stats["session_cost"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    /// Best-effort model name: config.model → agent_profile.overrides.model → "".
    private static func extractModel(_ obj: [String: Any]) -> String {
        if let m = (obj["config"] as? [String: Any])?["model"] as? String, !m.isEmpty {
            return m
        }
        if let overrides = (obj["agent_profile"] as? [String: Any])?["overrides"] as? [String: Any],
           let m = overrides["model"] as? String, !m.isEmpty {
            return m
        }
        return ""
    }
}

/// Derives lines-of-code added/removed from Vibe `messages.jsonl` edit tool calls.
enum VibeMessageParser {
    /// Counts logical lines, treating a single trailing newline as not adding a line.
    static func countLines(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        var n = 0
        for ch in s where ch == "\n" { n += 1 }
        if !s.hasSuffix("\n") { n += 1 }
        return n
    }

    /// Parse a chunk of messages.jsonl (one or more whole lines) and total LoC.
    static func parseEdits(_ data: Data) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                obj["role"] as? String == "assistant",
                let toolCalls = obj["tool_calls"] as? [[String: Any]]
            else { continue }

            for tc in toolCalls {
                guard
                    let fn = tc["function"] as? [String: Any],
                    let name = fn["name"] as? String,
                    let argsString = fn["arguments"] as? String,
                    let argsData = argsString.data(using: .utf8),
                    let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { continue }

                switch name {
                case "write_file":
                    if let content = args["content"] as? String {
                        added += countLines(content)
                    }
                case "edit":
                    if let newString = args["new_string"] as? String {
                        added += countLines(newString)
                    }
                    if let oldString = args["old_string"] as? String {
                        removed += countLines(oldString)
                    }
                default:
                    continue
                }
            }
        }
        return (added, removed)
    }
}

/// One scan's already-deltaed metrics for a single Vibe session.
struct VibeMetricDelta: Equatable {
    let sessionId: String
    let model: String
    let timestamp: String   // ISO-8601; used for timeUnixNano
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double
    let locAdded: Int
    let locRemoved: Int
    let isNewSession: Bool
}

/// Builds an OTLP/JSON metrics payload. All datapoints are DELTA temporality (1)
/// because the scanner already computed deltas; the backend SUMs them (deltaMetrics).
enum VibeOTelPayloadBuilder {
    static func buildMetricsPayload(deltas: [VibeMetricDelta]) -> [String: Any] {
        var resourceMetrics: [[String: Any]] = []

        for d in deltas {
            let nanos = isoToNanos(d.timestamp)
            var metrics: [[String: Any]] = []

            var tokenPoints: [[String: Any]] = []
            if d.inputTokens != 0 { tokenPoints.append(intPoint("input", d.inputTokens, model: d.model, nanos: nanos)) }
            if d.outputTokens != 0 { tokenPoints.append(intPoint("output", d.outputTokens, model: d.model, nanos: nanos)) }
            if !tokenPoints.isEmpty {
                metrics.append(sumMetric(name: "mistral_vibe.token.usage", points: tokenPoints))
            }

            if d.cost != 0 {
                metrics.append(sumMetric(
                    name: "mistral_vibe.cost.usage",
                    points: [doublePoint("usd", d.cost, model: d.model, nanos: nanos)]))
            }

            var locPoints: [[String: Any]] = []
            if d.locAdded != 0 { locPoints.append(intPoint("added", d.locAdded, model: d.model, nanos: nanos)) }
            if d.locRemoved != 0 { locPoints.append(intPoint("removed", d.locRemoved, model: d.model, nanos: nanos)) }
            if !locPoints.isEmpty {
                metrics.append(sumMetric(name: "mistral_vibe.lines_of_code.count", points: locPoints))
            }

            if d.isNewSession {
                metrics.append(sumMetric(
                    name: "mistral_vibe.session.count",
                    points: [intPoint("count", 1, model: d.model, nanos: nanos)]))
            }

            guard !metrics.isEmpty else { continue }

            resourceMetrics.append([
                "resource": [
                    "attributes": [
                        otelAttr("service.name", "mistral-vibe"),
                        otelAttr("session.id", d.sessionId),
                    ],
                ],
                "scopeMetrics": [[
                    "scope": ["name": "lobsterone.mac"],
                    "metrics": metrics,
                ]],
            ])
        }

        return ["resourceMetrics": resourceMetrics]
    }

    private static func sumMetric(name: String, points: [[String: Any]]) -> [String: Any] {
        [
            "name": name,
            "sum": [
                "aggregationTemporality": 1,
                "isMonotonic": true,
                "dataPoints": points,
            ],
        ]
    }

    private static func intPoint(_ type: String, _ value: Int, model: String, nanos: String) -> [String: Any] {
        [
            "attributes": [otelAttr("type", type), otelAttr("model", model)],
            "timeUnixNano": nanos,
            "asInt": String(value),
        ]
    }

    private static func doublePoint(_ type: String, _ value: Double, model: String, nanos: String) -> [String: Any] {
        [
            "attributes": [otelAttr("type", type), otelAttr("model", model)],
            "timeUnixNano": nanos,
            "asDouble": value,
        ]
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
