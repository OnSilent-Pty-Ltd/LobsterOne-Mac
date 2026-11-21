import Testing
import Foundation
@testable import LobsterOne

// MARK: - CodexSessionScanner Static Method Tests

@Test func scanFileExtractsSessionAndTokens() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let file = tmp.appendingPathComponent("session.jsonl")
    let lines = [
        #"{"timestamp":"2026-03-27T10:00:00.000Z","type":"session_meta","payload":{"id":"sess_abc123"}}"#,
        #"{"timestamp":"2026-03-27T10:00:01.000Z","type":"turn_context","payload":{"model":"o3-pro"}}"#,
        #"{"timestamp":"2026-03-27T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"output_tokens":200}}}}"#,
    ]
    try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    let events = CodexSessionScanner.parseFile(url: file, state: &state).tokens

    #expect(state.sessionId == "sess_abc123")
    #expect(state.lastModel == "o3-pro")
    #expect(state.lastTotals == TokenTotals(input: 1000, cached: 500, output: 200))
    #expect(events.count == 1)

    let event = events[0]
    #expect(event.sessionId == "sess_abc123")
    #expect(event.model == "o3-pro")
    // Delta from nil previous = same as totals
    #expect(event.delta == TokenTotals(input: 1000, cached: 500, output: 200))
    #expect(event.timestamp == "2026-03-27T10:00:02.000Z")
}

@Test func scanFileIncrementallyReadsOnlyNewBytes() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let file = tmp.appendingPathComponent("session.jsonl")
    let initialLines = [
        #"{"timestamp":"2026-03-27T10:00:00.000Z","type":"session_meta","payload":{"id":"sess_inc"}}"#,
        #"{"timestamp":"2026-03-27T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-4"}}"#,
        #"{"timestamp":"2026-03-27T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":20}}}}"#,
    ]
    try initialLines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    let firstEvents = CodexSessionScanner.parseFile(url: file, state: &state).tokens
    #expect(firstEvents.count == 1)
    #expect(firstEvents[0].delta == TokenTotals(input: 100, cached: 50, output: 20))

    // Append more data
    let appendLines = [
        #"{"timestamp":"2026-03-27T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":150,"output_tokens":60}}}}"#,
    ]
    let handle = try FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    handle.write(appendLines.joined(separator: "\n").appending("\n").data(using: .utf8)!)
    handle.closeFile()

    let secondEvents = CodexSessionScanner.parseFile(url: file, state: &state).tokens
    #expect(secondEvents.count == 1)
    // Delta should be from previous totals (100,50,20) to new (300,150,60)
    #expect(secondEvents[0].delta == TokenTotals(input: 200, cached: 100, output: 40))
    #expect(secondEvents[0].sessionId == "sess_inc")
    #expect(secondEvents[0].model == "gpt-4")
}

@Test func scanFileSkipsUnchangedFile() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let file = tmp.appendingPathComponent("session.jsonl")
    try "some data\n".write(to: file, atomically: true, encoding: .utf8)

    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    let mtime = (attrs[.modificationDate] as! Date).timeIntervalSince1970
    let size = attrs[.size] as! Int64

    let state = CodexFileState(
        mtimeUnixMs: Int64(mtime * 1000),
        size: size,
        parsedBytes: size
    )

    let skip = CodexSessionScanner.shouldSkipFile(url: file, state: state)
    #expect(skip == true)
}

@Test func discoverSessionFilesFindsJSONL() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Create today's date directory structure
    let cal = Calendar.current
    let now = Date()
    let y = cal.component(.year, from: now)
    let m = cal.component(.month, from: now)
    let d = cal.component(.day, from: now)
    let dateDir = tmp.appendingPathComponent("sessions")
        .appendingPathComponent(String(format: "%04d", y))
        .appendingPathComponent(String(format: "%02d", m))
        .appendingPathComponent(String(format: "%02d", d))
    try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

    // Create .jsonl and .txt files
    try "data".write(to: dateDir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    try "data".write(to: dateDir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
    try "data".write(to: dateDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

    let found = CodexSessionScanner.discoverSessionFiles(codexHome: tmp)
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.pathExtension == "jsonl" })
}

@Test func parseFileCapturesLatestRateLimits() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let file = tmp.appendingPathComponent("session.jsonl")
    let lines = [
        #"{"timestamp":"2026-04-09T10:00:00.000Z","type":"session_meta","payload":{"id":"sess_rl"}}"#,
        #"{"timestamp":"2026-04-09T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
        #"{"timestamp":"2026-04-09T10:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1775749388},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1776336188},"plan_type":"plus"}}}"#,
        #"{"timestamp":"2026-04-09T11:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1775749388},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1776336188},"plan_type":"plus"}}}"#,
    ]
    try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    let _ = CodexSessionScanner.parseFile(url: file, state: &state)

    #expect(state.lastRateLimitsTimestamp == "2026-04-09T11:30:00.000Z")
    #expect(state.lastRateLimits?.primary?.usedPercent == 42.5)
    #expect(state.lastRateLimits?.secondary?.usedPercent == 10.0)
    #expect(state.lastRateLimits?.planType == "plus")
}

// MARK: - Lines of code: one source per session

private func writeSession(_ lines: [String]) throws -> (URL, URL) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScannerTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent("session.jsonl")
    try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    return (tmp, file)
}

@Test func paginatedSessionCountsFileChangesNotApplyPatchCalls() throws {
    // A paginated session logs a direct apply_patch twice: raw call + FileChange item.
    let (tmp, file) = try writeSession([
        #"{"timestamp":"2026-10-23T01:53:22.289Z","type":"session_meta","payload":{"id":"sess_new","history_mode":"paginated"}}"#,
        #"{"timestamp":"2026-10-23T01:53:22.300Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}"#,
        #"{"timestamp":"2026-10-23T01:53:28.952Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","status":"completed","input":"*** Begin Patch\n*** Update File: /tmp/a.py\n@@\n-old\n+new\n*** End Patch"}}"#,
        #"{"timestamp":"2026-10-23T01:53:29.433Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"/tmp/a.py":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new\n"}}}}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: tmp) }

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    let lines = CodexSessionScanner.parseFile(url: file, state: &state).lines

    #expect(state.historyMode == "paginated")
    #expect(lines.count == 1)
    #expect(lines.first?.added == 1)
    #expect(lines.first?.removed == 1)
    #expect(lines.first?.model == "gpt-6-luna")
    #expect(lines.first?.timestamp == "2026-10-23T01:53:29.433Z")
}

@Test func legacySessionStillCountsApplyPatchCalls() throws {
    // Shape of a real June 2026 (Codex 0.14x) rollout: no history_mode, no FileChange items.
    let (tmp, file) = try writeSession([
        #"{"timestamp":"2026-06-18T05:30:48.000Z","type":"session_meta","payload":{"id":"sess_old"}}"#,
        #"{"timestamp":"2026-06-18T05:30:49.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
        #"{"timestamp":"2026-06-18T05:31:10.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_x","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /tmp/b.html\n@@\n-a\n+b\n+c\n*** End Patch"}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: tmp) }

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    let lines = CodexSessionScanner.parseFile(url: file, state: &state).lines

    #expect(state.historyMode == nil)
    #expect(lines.count == 1)
    #expect(lines.first?.added == 2)
    #expect(lines.first?.removed == 1)
}

@Test func historyModeSurvivesIncrementalScans() throws {
    // session_meta is only in the first chunk; later chunks must still use FileChange items.
    let (tmp, file) = try writeSession([
        #"{"timestamp":"2026-10-23T01:53:22.289Z","type":"session_meta","payload":{"id":"sess_new","history_mode":"paginated"}}"#,
        #"{"timestamp":"2026-10-23T01:53:22.300Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: tmp) }

    var state = CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    _ = CodexSessionScanner.parseFile(url: file, state: &state)

    let handle = try FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    handle.write(Data((#"{"timestamp":"2026-10-23T01:54:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","status":"completed","input":"+x"}}"# + "\n" +
        #"{"timestamp":"2026-10-23T01:54:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"/tmp/c.py":{"type":"add","content":"x\n"}}}}}"# + "\n").utf8))
    handle.closeFile()

    let lines = CodexSessionScanner.parseFile(url: file, state: &state).lines
    #expect(lines.count == 1)
    #expect(lines.first?.added == 1)
    #expect(lines.first?.timestamp == "2026-10-23T01:54:01.000Z")
}
