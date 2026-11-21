import Testing
import Foundation
@testable import LobsterOne

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func activityCountsEachClaudeResponseOnce() {
    var seen = RecentSet(capacity: 10)
    let first = line(#"{"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":4,"output_tokens":1219,"cache_read_input_tokens":599625}}}"#)
    #expect(ActivityEvent.parse(line: first, seenClaudeMessages: &seen) == ActivityEvent(tokens: 1223, source: .claude))
    // The same response written again as a second content block.
    #expect(ActivityEvent.parse(line: first, seenClaudeMessages: &seen) == nil)
    let next = line(#"{"type":"assistant","message":{"id":"msg_2","usage":{"input_tokens":2,"output_tokens":549}}}"#)
    #expect(ActivityEvent.parse(line: next, seenClaudeMessages: &seen)?.tokens == 551)
}

@Test func activityReadsCodexTurnsWithoutCachedInput() {
    var seen = RecentSet(capacity: 10)
    let turn = line(#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":18052,"cached_input_tokens":17792,"output_tokens":82}}}}"#)
    #expect(ActivityEvent.parse(line: turn, seenClaudeMessages: &seen) == ActivityEvent(tokens: 342, source: .codex))
}

@Test func activityIgnoresOtherLines() {
    var seen = RecentSet(capacity: 10)
    #expect(ActivityEvent.parse(line: line(#"{"type":"user","message":{"content":"hi"}}"#), seenClaudeMessages: &seen) == nil)
    #expect(ActivityEvent.parse(line: line(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}"#), seenClaudeMessages: &seen) == nil)
    #expect(ActivityEvent.parse(line: line("not json, mentions usage"), seenClaudeMessages: &seen) == nil)
}

@Test func logTailConsumesOnlyWholeLines() {
    let (lines, consumed) = LogTail.completeLines(in: Data("a\nbb\n\ncc".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "bb"])
    #expect(consumed == 6)
}

@Test func logTailFollowsAGrowingFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
    try Data("one\ntw".utf8).write(to: url)
    var tail = LogTail(offset: 0)
    let firstRead = tail.readNewLines(path: url.path)
    #expect(firstRead.count == 1)

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("o\nthree\n".utf8))
    try handle.close()
    let secondRead = tail.readNewLines(path: url.path).map { String(decoding: $0, as: UTF8.self) }
    #expect(secondRead == ["two", "three"])

    // Rewritten shorter: starts again from the top.
    try Data("new\n".utf8).write(to: url)
    let thirdRead = tail.readNewLines(path: url.path).map { String(decoding: $0, as: UTF8.self) }
    #expect(thirdRead == ["new"])
}

@Test func recentSetForgetsOldest() {
    var set = RecentSet(capacity: 2)
    let results = ["a", "b", "a", "c", "a"].map { set.insert($0) }
    // "a" is refused while held, then accepted again once "c" pushes it out.
    #expect(results == [true, true, false, true, true])
}

@Test func activityTellsAnswersToolsAndEditsApart() {
    var seen = RecentSet(capacity: 10)
    let answer = line(#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":2,"output_tokens":80}}}"#)
    let tool = line(#"{"type":"assistant","message":{"id":"b","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":2,"output_tokens":80}}}"#)
    let edit = line(#"{"type":"assistant","message":{"id":"c","content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Edit"}],"usage":{"input_tokens":2,"output_tokens":80}}}"#)
    #expect(ActivityEvent.parse(line: answer, seenClaudeMessages: &seen)?.kind == .answer)
    #expect(ActivityEvent.parse(line: tool, seenClaudeMessages: &seen)?.kind == .tool)
    #expect(ActivityEvent.parse(line: edit, seenClaudeMessages: &seen)?.kind == .edit)
}

@Test func codexToolCallLinesCarryAKind() {
    #expect(ActivityEvent.codexCallKind(line: line(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"..."}}"#)) == .edit)
    #expect(ActivityEvent.codexCallKind(line: line(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#)) == .tool)
    #expect(ActivityEvent.codexCallKind(line: line(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"x"}}"#)) == nil)
    #expect(ActivityEvent.codexCallKind(line: line(#"{"type":"response_item","payload":{"type":"message","role":"user"}}"#)) == nil)
}
