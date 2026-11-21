import Foundation

// MARK: - Scanner Cache (persisted to disk)

struct ClaudeScannerCache: Codable {
    var lastScanUnixMs: Int64 = 0
    var files: [String: ClaudeFileState] = [:]
}

struct ClaudeFileState: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    var sessionId: String?
    var startedAt: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var firstPrompt: String?
    /// Token count at last upload — used to detect changed sessions
    var lastUploadedTokens: Int = 0

    // Analytics fields
    var sessionTitle: String?
    var gitBranch: String?
    var primaryModel: String?
    var toolCallCount: Int = 0
    var toolErrorCount: Int = 0
    var filesModifiedCount: Int = 0
    var planModeTurns: Int = 0
    var executionTurns: Int = 0
    var toolCalls: [ToolCallRecord] = []
    var modelUsage: [String: ModelTokenRecord] = [:]
    var filesModified: Set<String> = []
}

struct ToolCallRecord: Codable, Hashable {
    var toolName: String
    var isError: Bool = false
    var filePath: String?
    var timestamp: String?
}

struct ModelTokenRecord: Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var messageCount: Int = 0
}

// MARK: - Import API Payload

struct SessionImportPayload: Encodable {
    let sessions: [SessionImportItem]
}

struct SessionImportItem: Encodable {
    let session_id: String
    let parent_session_id: String?
    let is_subagent: Bool
    let project_path: String?
    let started_at: String?
    let input_tokens: Int
    let output_tokens: Int
    let cache_read_tokens: Int
    let cache_creation_tokens: Int
    let subagent_count: Int
    let subagent_tokens: Int
    let first_prompt: String?
    // Analytics fields
    let session_title: String?
    let git_branch: String?
    let primary_model: String?
    let tool_call_count: Int
    let tool_error_count: Int
    let files_modified_count: Int
    let plan_mode_turns: Int
    let execution_turns: Int
    let tool_calls: [ToolCallImportItem]?
    let model_usage: [ModelUsageImportItem]?
}

struct ToolCallImportItem: Encodable {
    let tool_name: String
    let is_error: Bool
    let file_path: String?
    let timestamp: String?
}

struct ModelUsageImportItem: Encodable {
    let model: String
    let input_tokens: Int
    let output_tokens: Int
    let cache_read_tokens: Int
    let cache_creation_tokens: Int
    let message_count: Int
}

// MARK: - JSONL Parser

enum ClaudeJSONLParser {
    struct ParsedLine {
        enum Kind {
            case assistantUsage(model: String?, input: Int, output: Int, cacheRead: Int, cacheCreation: Int)
            case toolUse(id: String?, name: String, filePath: String?, timestamp: String?)
            case toolResult(toolUseId: String, isError: Bool)
            case humanPrompt(text: String, timestamp: String?)
            case metadata(sessionId: String?, agentId: String?, timestamp: String?, gitBranch: String?, permissionMode: String?)
            case sessionTitle(title: String)
        }
        let kind: Kind
    }

    static func parseLine(_ data: Data) -> [ParsedLine] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let type = obj["type"] as? String
        let timestamp = obj["timestamp"] as? String
        let sessionId = obj["sessionId"] as? String
        let agentId = obj["agentId"] as? String
        let gitBranch = obj["gitBranch"] as? String
        let permissionMode = obj["permissionMode"] as? String
        let message = obj["message"] as? [String: Any]

        var results: [ParsedLine] = []

        // Session title
        if type == "custom-title", let title = obj["customTitle"] as? String {
            results.append(ParsedLine(kind: .sessionTitle(title: title)))
        }

        // Assistant message — extract model, tokens, and tool_use calls
        if type == "assistant" {
            let model = message?["model"] as? String

            if let usage = message?["usage"] as? [String: Any] {
                results.append(ParsedLine(kind: .assistantUsage(
                    model: model,
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
                )))
            }

            // Extract tool_use calls from content
            if let content = message?["content"] as? [[String: Any]] {
                for item in content where item["type"] as? String == "tool_use" {
                    let toolUseId = item["id"] as? String
                    let toolName = item["name"] as? String ?? "unknown"
                    let filePath = extractFilePath(toolName: toolName, input: item["input"] as? [String: Any])
                    results.append(ParsedLine(kind: .toolUse(id: toolUseId, name: toolName, filePath: filePath, timestamp: timestamp)))
                }
            }
        }

        // User message — extract tool results (for error tracking) and human prompts
        if type == "user" {
            let userType = obj["userType"] as? String ?? ""
            let isSidechain = obj["isSidechain"] as? Bool ?? false

            if let content = message?["content"] as? [[String: Any]] {
                for item in content {
                    if item["type"] as? String == "tool_result" {
                        let toolUseId = item["tool_use_id"] as? String ?? ""
                        let isError = item["is_error"] as? Bool ?? false
                        results.append(ParsedLine(kind: .toolResult(toolUseId: toolUseId, isError: isError)))
                    }
                }
            }

            if !isSidechain && userType != "tool" {
                let text = extractTextContent(message?["content"])
                if let text, !text.isEmpty, isHumanPrompt(content: message?["content"]) {
                    results.append(ParsedLine(kind: .humanPrompt(text: text, timestamp: timestamp)))
                }
            }
        }

        // Metadata from any message type
        if sessionId != nil || agentId != nil || timestamp != nil || gitBranch != nil || permissionMode != nil {
            results.append(ParsedLine(kind: .metadata(
                sessionId: sessionId, agentId: agentId, timestamp: timestamp,
                gitBranch: gitBranch, permissionMode: permissionMode
            )))
        }

        return results
    }

    /// Extract file_path from tool input for file-related tools
    private static func extractFilePath(toolName: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch toolName {
        case "Read", "Write", "Edit":
            return input["file_path"] as? String
        case "Bash":
            return nil // Bash commands don't target a single file
        case "Glob":
            return input["pattern"] as? String
        case "Grep":
            return input["path"] as? String
        default:
            return nil
        }
    }

    private static func extractTextContent(_ content: Any?) -> String? {
        if let text = content as? String {
            return text.isEmpty ? nil : text
        }
        if let items = content as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func isHumanPrompt(content: Any?) -> Bool {
        guard let items = content as? [[String: Any]] else { return true }
        let types = items.compactMap { $0["type"] as? String }
        if !types.isEmpty && types.allSatisfy({ $0 == "tool_result" }) {
            return false
        }
        return true
    }
}
