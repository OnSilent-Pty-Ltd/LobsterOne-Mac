import Foundation
import Testing
@testable import LobsterOne

private func makeSessionsDir() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func discoverFindsSessionFoldersWithMeta() throws {
    let root = try makeSessionsDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let s1 = root.appendingPathComponent("session_20260608_100000_abc")
    try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
    try "{}".write(to: s1.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

    let s2 = root.appendingPathComponent("session_20260608_110000_def")
    try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)

    let found = MistralVibeSessionScanner.discoverSessionFolders(sessionsDir: root)
    #expect(found.map { $0.lastPathComponent } == ["session_20260608_100000_abc"])
}

private func writeMeta(_ dir: URL, prompt: Int, completion: Int, cost: Double, model: String = "devstral-2") throws {
    let json = """
    {"session_id":"\(dir.lastPathComponent)","git_branch":"main",
     "stats":{"session_prompt_tokens":\(prompt),"session_completion_tokens":\(completion),"session_cost":\(cost)},
     "config":{"model":"\(model)"}}
    """
    try json.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
}

@Test func processFolderEmitsCumulativeDeltaAndSessionOnce() throws {
    let root = try makeSessionsDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("session_20260608_100000_abc")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    try writeMeta(dir, prompt: 100, completion: 20, cost: 0.01)
    try #"{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"a.py\",\"content\":\"l1\\nl2\\n\"}"}}]}"#
        .appending("\n").write(to: dir.appendingPathComponent("messages.jsonl"), atomically: true, encoding: .utf8)

    var state = VibeFolderState()
    let first = MistralVibeSessionScanner.processFolder(url: dir, state: &state)
    #expect(first.deltas.count == 1)
    #expect(first.deltas[0].inputTokens == 100)
    #expect(first.deltas[0].outputTokens == 20)
    #expect(first.deltas[0].cost == 0.01)
    #expect(first.deltas[0].locAdded == 2)
    #expect(first.deltas[0].isNewSession == true)
    #expect(first.deltas[0].model == "devstral-2")

    try writeMeta(dir, prompt: 250, completion: 45, cost: 0.025)
    let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("messages.jsonl"))
    handle.seekToEndOfFile()
    handle.write((#"{"role":"assistant","tool_calls":[{"id":"c2","type":"function","function":{"name":"edit","arguments":"{\"file_path\":\"a.py\",\"old_string\":\"x\",\"new_string\":\"x\\ny\"}"}}]}"# + "\n").data(using: .utf8)!)
    handle.closeFile()

    let second = MistralVibeSessionScanner.processFolder(url: dir, state: &state)
    #expect(second.deltas.count == 1)
    #expect(second.deltas[0].inputTokens == 150)
    #expect(second.deltas[0].outputTokens == 25)
    #expect(abs(second.deltas[0].cost - 0.015) < 1e-9)
    #expect(second.deltas[0].locAdded == 2)
    #expect(second.deltas[0].locRemoved == 1)
    #expect(second.deltas[0].isNewSession == false)
}

@Test func processFolderSkipsWhenUnchanged() throws {
    let root = try makeSessionsDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("session_x")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeMeta(dir, prompt: 10, completion: 5, cost: 0)

    var state = VibeFolderState()
    _ = MistralVibeSessionScanner.processFolder(url: dir, state: &state)
    let again = MistralVibeSessionScanner.processFolder(url: dir, state: &state)
    #expect(again.deltas.isEmpty)
}
