import Testing
import Foundation
@testable import LobsterOne

private func sampleState() -> ClaudeFileState {
    var state = ClaudeFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
    state.inputTokens = 1200
    state.outputTokens = 340
    state.firstPrompt = "Fix the invoice export for Acme"
    state.sessionTitle = "Invoice export"
    state.gitBranch = "fix/invoice-export"
    state.toolCalls = [
        ToolCallRecord(toolName: "Edit", isError: false, filePath: "/work/acme/api/export.ts", timestamp: "2026-11-21T05:00:00Z"),
        ToolCallRecord(toolName: "Bash", isError: true, filePath: nil, timestamp: "2026-11-21T05:01:00Z"),
    ]
    state.toolCallCount = 2
    return state
}

private func item(includeDetails: Bool) -> SessionImportItem {
    ClaudeSessionScanner.buildImportItem(
        state: sampleState(), sessionId: "s1", parentSessionId: nil,
        isSubagent: false, projectName: "work-acme",
        subagentCount: 0, subagentTokens: 0,
        includeDetails: includeDetails
    )
}

@Test func sessionDetailsAreSentByDefault() {
    let sent = item(includeDetails: true)
    #expect(sent.first_prompt == "Fix the invoice export for Acme")
    #expect(sent.session_title == "Invoice export")
    #expect(sent.tool_calls?.first?.file_path == "/work/acme/api/export.ts")
}

@Test func sessionDetailsOffKeepsPromptTitleAndPathsOnTheMac() {
    let sent = item(includeDetails: false)
    #expect(sent.first_prompt == nil)
    #expect(sent.session_title == nil)
    #expect(sent.tool_calls?.allSatisfy { $0.file_path == nil } == true)
}

@Test func sessionDetailsOffStillSendsUsageAndProject() {
    let sent = item(includeDetails: false)
    #expect(sent.input_tokens == 1200)
    #expect(sent.output_tokens == 340)
    #expect(sent.project_path == "work-acme")
    #expect(sent.git_branch == "fix/invoice-export")
    #expect(sent.tool_calls?.map(\.tool_name) == ["Edit", "Bash"])
    #expect(sent.tool_calls?.map(\.is_error) == [false, true])
}

@Test func sessionDetailsPreferenceDefaultsToOnAndFollowsTheStoredValue() throws {
    let suite = "SessionDetailsPreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(SessionDetailsPreference.isEnabled(defaults))
    defaults.set(false, forKey: SessionDetailsPreference.key)
    #expect(!SessionDetailsPreference.isEnabled(defaults))
}
