import Foundation
import Testing
@testable import LobsterOne

@Test func parseMetaExtractsCumulativeStats() {
    let json = """
    {"session_id":"sess_1","parent_session_id":null,"git_branch":"main",
     "stats":{"session_prompt_tokens":14860,"session_completion_tokens":288,
              "session_cost":0.0123,"tool_calls_succeeded":5,"tool_calls_failed":1},
     "config":{"model":"devstral-2"}}
    """
    let stats = VibeMetaParser.parse(json.data(using: .utf8)!)
    #expect(stats?.sessionId == "sess_1")
    #expect(stats?.parentSessionId == nil)
    #expect(stats?.model == "devstral-2")
    #expect(stats?.gitBranch == "main")
    #expect(stats?.promptTokens == 14860)
    #expect(stats?.completionTokens == 288)
    #expect(stats?.cost == 0.0123)
}

@Test func parseMetaToleratesMissingModel() {
    let json = """
    {"session_id":"sess_2","stats":{"session_prompt_tokens":1,"session_completion_tokens":2,"session_cost":0}}
    """
    let stats = VibeMetaParser.parse(json.data(using: .utf8)!)
    #expect(stats?.model == "")
    #expect(stats?.cost == 0)
}

@Test func parseMetaReturnsNilWhenStatsMissing() {
    #expect(VibeMetaParser.parse("{\"session_id\":\"x\"}".data(using: .utf8)!) == nil)
}

@Test func countLinesHandlesTrailingNewline() {
    #expect(VibeMessageParser.countLines("") == 0)
    #expect(VibeMessageParser.countLines("x = 1") == 1)
    #expect(VibeMessageParser.countLines("x = 1\ny = 2") == 2)
    #expect(VibeMessageParser.countLines("x = 1\ny = 2\n") == 2)
}

@Test func parseEditsCountsWriteFileAndEdit() {
    let lines = [
        #"{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"a.py\",\"content\":\"def f():\\n    return 1\\n\"}"}}]}"#,
        #"{"role":"assistant","tool_calls":[{"id":"c2","type":"function","function":{"name":"edit","arguments":"{\"file_path\":\"a.py\",\"old_string\":\"x = 1\",\"new_string\":\"x = 1\\ny = 2\"}"}}]}"#,
        #"{"role":"tool","name":"edit","tool_call_id":"c2","content":"ok"}"#,
        #"{"role":"user","content":"thanks"}"#,
    ].joined(separator: "\n") + "\n"

    let result = VibeMessageParser.parseEdits(lines.data(using: .utf8)!)
    #expect(result.added == 4)   // 2 (write_file) + 2 (edit new_string)
    #expect(result.removed == 1) // edit old_string
}

@Test func otelPayloadEmitsTokenCostLocAndSession() {
    let delta = VibeMetricDelta(
        sessionId: "sess_1", model: "devstral-2", timestamp: "2026-06-08T10:00:00Z",
        inputTokens: 100, outputTokens: 20, cost: 0.0123,
        locAdded: 4, locRemoved: 1, isNewSession: true)

    let payload = VibeOTelPayloadBuilder.buildMetricsPayload(deltas: [delta])
    let rms = payload["resourceMetrics"] as! [[String: Any]]
    #expect(rms.count == 1)

    let metrics = ((rms[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]])
    let names = Set(metrics.compactMap { $0["name"] as? String })
    #expect(names == [
        "mistral_vibe.token.usage",
        "mistral_vibe.cost.usage",
        "mistral_vibe.lines_of_code.count",
        "mistral_vibe.session.count",
    ])

    let attrs = (rms[0]["resource"] as! [String: Any])["attributes"] as! [[String: Any]]
    let service = attrs.first { ($0["key"] as? String) == "service.name" }
    #expect(((service?["value"] as? [String: Any])?["stringValue"] as? String) == "mistral-vibe")
}

@Test func otelPayloadSkipsSessionCountWhenNotNew() {
    let delta = VibeMetricDelta(
        sessionId: "s", model: "", timestamp: "2026-06-08T10:00:00Z",
        inputTokens: 1, outputTokens: 1, cost: 0, locAdded: 0, locRemoved: 0, isNewSession: false)
    let payload = VibeOTelPayloadBuilder.buildMetricsPayload(deltas: [delta])
    let metrics = (((payload["resourceMetrics"] as! [[String: Any]])[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]])
    let names = Set(metrics.compactMap { $0["name"] as? String })
    #expect(!names.contains("mistral_vibe.session.count"))
    #expect(!names.contains("mistral_vibe.lines_of_code.count"))
}

@Test func otelPayloadUsesZeroNanosForBadTimestamp() {
    let delta = VibeMetricDelta(
        sessionId: "s", model: "", timestamp: "not-a-date",
        inputTokens: 5, outputTokens: 0, cost: 0, locAdded: 0, locRemoved: 0, isNewSession: false)
    let payload = VibeOTelPayloadBuilder.buildMetricsPayload(deltas: [delta])
    let metrics = (((payload["resourceMetrics"] as! [[String: Any]])[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]])
    let tokenMetric = metrics.first { ($0["name"] as? String) == "mistral_vibe.token.usage" }!
    let points = (tokenMetric["sum"] as! [String: Any])["dataPoints"] as! [[String: Any]]
    #expect((points[0]["timeUnixNano"] as? String) == "0")
}
