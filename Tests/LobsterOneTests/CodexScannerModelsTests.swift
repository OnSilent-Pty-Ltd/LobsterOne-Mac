import Testing
import Foundation
@testable import LobsterOne

// MARK: - JSONL Parser Tests

@Test func parseSessionMetaExtractsSessionId() {
    let json = """
    {"timestamp":"2026-03-27T10:00:00.000Z","type":"session_meta","payload":{"id":"sess_abc123"}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .sessionMeta(sessionId: "sess_abc123", historyMode: nil))
}

@Test func parseSessionMetaExtractsHistoryMode() {
    let json = """
    {"timestamp":"2026-10-23T01:53:22.289Z","type":"session_meta","payload":{"id":"sess_new","cli_version":"0.163.0","history_mode":"paginated"}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .sessionMeta(sessionId: "sess_new", historyMode: "paginated"))
}

@Test func parseTurnContextExtractsModel() {
    let json = """
    {"timestamp":"2026-03-27T10:00:01.000Z","type":"turn_context","payload":{"model":"o3-pro"}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .turnContext(model: "o3-pro"))
}

@Test func parseTokenCountExtractsTotals() {
    let json = """
    {"timestamp":"2026-03-27T11:03:19.532Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":14860,"cached_input_tokens":14720,"output_tokens":288}}}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .tokenCount(
        timestamp: "2026-03-27T11:03:19.532Z",
        totals: TokenTotals(input: 14860, cached: 14720, output: 288)
    ))
}

@Test func parseTokenCountWithNullInfoReturnsNil() {
    let json = """
    {"timestamp":"2026-03-27T11:03:19.532Z","type":"event_msg","payload":{"type":"token_count","info":null}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == nil)
}

@Test func parseUnrelatedEventReturnsNil() {
    let json = """
    {"timestamp":"2026-03-27T10:00:00.000Z","type":"response_item","payload":{"text":"hello"}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == nil)
}

@Test func parseMalformedLineReturnsNil() {
    let event = CodexJSONLParser.parseLine("not valid json{{{".data(using: .utf8)!)
    #expect(event == nil)
}

// MARK: - TokenTotals Delta Tests

@Test func deltaFromCumulativeTotals() {
    let previous = TokenTotals(input: 100, cached: 50, output: 30)
    let current = TokenTotals(input: 250, cached: 120, output: 80)
    let delta = current.delta(from: previous)
    #expect(delta == TokenTotals(input: 150, cached: 70, output: 50))
}

@Test func deltaFromNilPreviousReturnsCurrent() {
    let current = TokenTotals(input: 250, cached: 120, output: 80)
    let delta = current.delta(from: nil)
    #expect(delta == current)
}

@Test func deltaClampsNegativeToZero() {
    let previous = TokenTotals(input: 500, cached: 300, output: 200)
    let current = TokenTotals(input: 100, cached: 50, output: 30)
    let delta = current.delta(from: previous)
    #expect(delta == TokenTotals(input: 0, cached: 0, output: 0))
    #expect(delta.isZero)
}

// MARK: - OTel Payload Builder Tests

@Test func otelPayloadStructure() {
    let events = [
        TokenEvent(
            timestamp: "2026-03-27T11:03:19.532Z",
            model: "o3-pro",
            sessionId: "sess_abc123",
            delta: TokenTotals(input: 150, cached: 70, output: 50)
        )
    ]
    let payload = OTelPayloadBuilder.buildMetricsPayload(events: events)

    let resourceMetrics = payload["resourceMetrics"] as! [[String: Any]]
    #expect(resourceMetrics.count == 1)

    let rm = resourceMetrics[0]
    let resource = rm["resource"] as! [String: Any]
    let attrs = resource["attributes"] as! [[String: Any]]
    // Check service.name and session.id attributes
    let attrMap = Dictionary(uniqueKeysWithValues: attrs.map { ($0["key"] as! String, $0["value"] as! [String: Any]) })
    #expect(attrMap["service.name"]?["stringValue"] as? String == "codex")
    #expect(attrMap["session.id"]?["stringValue"] as? String == "sess_abc123")

    let scopeMetrics = rm["scopeMetrics"] as! [[String: Any]]
    #expect(scopeMetrics.count == 1)
    let scope = scopeMetrics[0]["scope"] as! [String: Any]
    #expect(scope["name"] as? String == "lobsterone.mac")

    let metrics = scopeMetrics[0]["metrics"] as! [[String: Any]]
    #expect(metrics.count == 1)
    let metric = metrics[0]
    #expect(metric["name"] as? String == "codex.token.usage")

    let sum = metric["sum"] as! [String: Any]
    #expect(sum["aggregationTemporality"] as? Int == 2)
    #expect(sum["isMonotonic"] as? Bool == true)

    let dataPoints = sum["dataPoints"] as! [[String: Any]]
    // 3 non-zero token types
    #expect(dataPoints.count == 3)

    // Verify each datapoint has token type and model attributes
    for dp in dataPoints {
        let dpAttrs = dp["attributes"] as! [[String: Any]]
        let dpAttrMap = Dictionary(uniqueKeysWithValues: dpAttrs.map { ($0["key"] as! String, $0["value"] as! [String: Any]) })
        #expect(dpAttrMap["model"]?["stringValue"] as? String == "o3-pro")
        #expect(dpAttrMap["type"]?["stringValue"] as? String != nil)
        #expect(dp["asInt"] as? String != nil)
        #expect(dp["timeUnixNano"] as? String != nil)
    }
}

@Test func otelPayloadGroupsBySession() {
    let events = [
        TokenEvent(
            timestamp: "2026-03-27T11:00:00.000Z",
            model: "o3-pro",
            sessionId: "sess_1",
            delta: TokenTotals(input: 100, cached: 0, output: 50)
        ),
        TokenEvent(
            timestamp: "2026-03-27T11:01:00.000Z",
            model: "o3-pro",
            sessionId: "sess_2",
            delta: TokenTotals(input: 200, cached: 0, output: 100)
        ),
    ]
    let payload = OTelPayloadBuilder.buildMetricsPayload(events: events)
    let resourceMetrics = payload["resourceMetrics"] as! [[String: Any]]
    #expect(resourceMetrics.count == 2)
}

@Test func otelPayloadSkipsZeroDeltaEvents() {
    let events = [
        TokenEvent(
            timestamp: "2026-03-27T11:00:00.000Z",
            model: "o3-pro",
            sessionId: "sess_1",
            delta: TokenTotals(input: 0, cached: 0, output: 0)
        ),
    ]
    let payload = OTelPayloadBuilder.buildMetricsPayload(events: events)
    let resourceMetrics = payload["resourceMetrics"] as! [[String: Any]]
    #expect(resourceMetrics.isEmpty)
}

// MARK: - Rate Limits Parser Tests

@Test func parseRateLimitsFromNullInfoTokenCount() {
    let json = """
    {"timestamp":"2026-04-09T10:43:08.836Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1775749388},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1776336188},"plan_type":"plus"}}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .rateLimits(
        timestamp: "2026-04-09T10:43:08.836Z",
        limits: CodexRateLimits(
            primary: CodexRateWindow(usedPercent: 42.5, windowMinutes: 300, resetsAt: 1775749388),
            secondary: CodexRateWindow(usedPercent: 10.0, windowMinutes: 10080, resetsAt: 1776336188),
            planType: "plus"
        )
    ))
}

@Test func parseTokenCountWithUsageStillReturnsTokenCount() {
    let json = """
    {"timestamp":"2026-04-09T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}}}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .tokenCount(timestamp: "2026-04-09T11:00:00.000Z", totals: TokenTotals(input: 100, cached: 0, output: 20)))
}

@Test func parseTokenCountNullInfoNoRateLimitsReturnsNil() {
    let json = """
    {"timestamp":"2026-04-09T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}
    """
    #expect(CodexJSONLParser.parseLine(json.data(using: .utf8)!) == nil)
}

// MARK: - apply_patch Line Counting Tests

@Test func countPatchLinesCountsAddedAndRemoved() {
    // V4A patch: `+`/`-`/` ` line prefixes; `*** ` and `@@` lines are not counted.
    let patch = """
    *** Begin Patch
    *** Update File: /tmp/foo.ts
    @@
     unchanged context line
    -old line one
    -old line two
    +new line one
    +new line two
    +new line three
    *** End Patch
    """
    let counts = CodexJSONLParser.countPatchLines(patch)
    #expect(counts.added == 3)
    #expect(counts.removed == 2)
}

@Test func countPatchLinesAddFileCountsAllAdditions() {
    let patch = """
    *** Begin Patch
    *** Add File: /tmp/new.txt
    +line a
    +line b
    *** End Patch
    """
    let counts = CodexJSONLParser.countPatchLines(patch)
    #expect(counts.added == 2)
    #expect(counts.removed == 0)
}

@Test func parseApplyPatchReturnsPatchApplied() {
    // input is a JSON string, so newlines/quotes are escaped.
    let input = "*** Begin Patch\\n*** Update File: /tmp/foo.ts\\n@@\\n unchanged\\n-removed\\n+added one\\n+added two\\n*** End Patch"
    let json = """
    {"timestamp":"2026-03-26T08:56:37.618Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","status":"completed","call_id":"call_x","input":"\(input)"}}
    """
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .patchApplied(timestamp: "2026-03-26T08:56:37.618Z", added: 2, removed: 1))
}

@Test func parseApplyPatchIgnoresNonCompletedStatus() {
    let json = """
    {"timestamp":"2026-03-26T08:56:37.618Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","status":"in_progress","input":"+added"}}
    """
    #expect(CodexJSONLParser.parseLine(json.data(using: .utf8)!) == nil)
}

@Test func parseResponseItemWithoutPatchReturnsNil() {
    let json = """
    {"timestamp":"2026-03-27T10:00:00.000Z","type":"response_item","payload":{"text":"hello"}}
    """
    #expect(CodexJSONLParser.parseLine(json.data(using: .utf8)!) == nil)
}

@Test func otelPayloadEmitsLinesOfCodeMetric() {
    let lines = [
        LineEvent(timestamp: "2026-03-26T08:56:37.618Z", model: "gpt-5.5", sessionId: "sess_x", added: 73, removed: 18)
    ]
    let payload = OTelPayloadBuilder.buildMetricsPayload(events: [], lineEvents: lines)
    let resourceMetrics = payload["resourceMetrics"] as! [[String: Any]]
    #expect(resourceMetrics.count == 1)

    let metrics = (resourceMetrics[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]]
    #expect(metrics[0]["name"] as? String == "codex.lines_of_code.count")

    let dataPoints = (metrics[0]["sum"] as! [String: Any])["dataPoints"] as! [[String: Any]]
    #expect(dataPoints.count == 2)  // added + removed
    let byType = Dictionary(uniqueKeysWithValues: dataPoints.map { dp -> (String, String) in
        let attrs = dp["attributes"] as! [[String: Any]]
        let map = Dictionary(uniqueKeysWithValues: attrs.map { ($0["key"] as! String, $0["value"] as! [String: Any]) })
        return (map["type"]!["stringValue"] as! String, dp["asInt"] as! String)
    })
    #expect(byType["added"] == "73")
    #expect(byType["removed"] == "18")
}

// MARK: - FileChange items (paginated sessions, Codex 0.16x)

// Trimmed from a real Codex 0.163 rollout: the edit ran inside a code-mode
// `exec` script, so the only record of it is this FileChange item.
@Test func parseFileChangeUpdateCountsUnifiedDiff() {
    let json = #"""
    {"timestamp":"2026-10-23T01:53:29.433Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":{"type":"FileChange","id":"exec-93a7e2f7","changes":{"/tmp/hello.py":{"type":"update","unified_diff":"@@ -1,2 +1,6 @@\n def hello():\n-    return \"hello\"\n+    return \"hello world\"\n+\n+\n+def goodbye():\n+    return \"goodbye\"\n","move_path":null}},"status":"completed","stdout":"Success. Updated the following files:\nM hello.py\n","stderr":""}}}
    """#
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .fileChangeApplied(timestamp: "2026-10-23T01:53:29.433Z", added: 5, removed: 1))
}

@Test func parseFileChangeCountsAddedAndDeletedFiles() {
    let json = #"""
    {"timestamp":"2026-10-23T02:00:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"/tmp/new.ts":{"type":"add","content":"a\nb\nc\n"},"/tmp/old.ts":{"type":"delete","content":"x\ny"}}}}}
    """#
    let event = CodexJSONLParser.parseLine(json.data(using: .utf8)!)
    #expect(event == .fileChangeApplied(timestamp: "2026-10-23T02:00:00.000Z", added: 3, removed: 2))
}

@Test func parseFileChangeIgnoresFailedChanges() {
    let json = #"""
    {"timestamp":"2026-10-23T02:00:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"failed","changes":{"/tmp/a.ts":{"type":"add","content":"a\n"}}}}}
    """#
    #expect(CodexJSONLParser.parseLine(json.data(using: .utf8)!) == nil)
}

@Test func parseItemCompletedNonFileChangeReturnsNil() {
    let json = #"""
    {"timestamp":"2026-10-23T01:53:24.386Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"m","content":[]}}}
    """#
    #expect(CodexJSONLParser.parseLine(json.data(using: .utf8)!) == nil)
}
