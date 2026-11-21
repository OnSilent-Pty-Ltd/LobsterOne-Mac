import Combine
import Foundation

/// Scans ~/.claude/projects/ for session JSONL files, extracts token usage and
/// subagent hierarchy, and uploads enriched session data to the Robocog backend.
/// Mirrors the CodexSessionScanner pattern but uses structured session import
/// instead of OTel metrics forwarding.
@MainActor
final class ClaudeSessionScanner: ObservableObject {
    let activeInterval: TimeInterval = Constants.scannerActiveInterval
    let idleInterval: TimeInterval = Constants.scannerIdleInterval

    private let activityMonitor: ActivityMonitor
    private let clientPolicy: ClientPolicyService
    private let ingestURL: String
    private let projectsDir: URL
    private let cachePath: URL
    /// Whether Claude Code is connected to LobsterOne (our key is in its settings). Checked
    /// before every scan, so disconnecting stops uploads within a minute and they stay stopped
    /// across restarts, however the scanner was started.
    private let isConnected: () -> Bool

    private var apiKey: String?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var cache = ClaudeScannerCache()
    private var username: String?
    private var skippingDisconnected = false

    init(
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        clientPolicy: ClientPolicyService? = nil,
        ingestURL: String = Constants.ingestURL,
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        cachePath: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LobsterOne/claude-scanner-cache.json"),
        isConnected: @escaping () -> Bool = { ConfigService().readAPIKey() != nil }
    ) {
        self.activityMonitor = activityMonitor
        self.clientPolicy = clientPolicy ?? ClientPolicyService()
        self.ingestURL = ingestURL
        self.projectsDir = projectsDir
        self.cachePath = cachePath
        self.isConnected = isConnected
    }

    func start(apiKey: String) {
        self.apiKey = apiKey
        self.username = NSUserName()
        loadCache()

        cancellable = activityMonitor.$isSleeping
            .dropFirst()
            .sink { [weak self] isSleeping in
                guard let self else { return }
                if isSleeping {
                    self.timer?.invalidate()
                    self.timer = nil
                } else {
                    Task { @MainActor in
                        await self.scanAndScheduleNext()
                    }
                }
            }

        Task {
            await scanAndScheduleNext()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellable?.cancel()
        cancellable = nil
        apiKey = nil
    }

    /// Clear the scan cache and immediately re-scan all session files.
    /// The next upload will re-import everything, recalculating cost estimates.
    func forceRescan() async {
        cache = ClaudeScannerCache()
        saveCache()
        await scan()
    }

    // MARK: - Scan Cycle

    private func scanAndScheduleNext() async {
        await scan()
        scheduleNext()
    }

    private func scan() async {
        guard isConnected() else {
            if !skippingDisconnected {
                DebugLog.shared.log("[ClaudeScanner] Claude Code isn't connected; nothing is sent until it is")
                skippingDisconnected = true
            }
            return
        }
        skippingDisconnected = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return }

        var allSessions = [SessionImportItem]()
        // Track cache key -> session_id for efficient post-upload marking
        var uploadedCacheKeys = [String]()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let projectName = Self.projectName(from: projectDir.lastPathComponent, username: username)

            // Find JSONL files in the project directory
            guard let jsonlFiles = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for jsonlFile in jsonlFiles where jsonlFile.pathExtension == "jsonl" {
                let key = jsonlFile.path
                var state = cache.files[key] ?? ClaudeFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)

                // Parse new bytes if file changed
                if !Self.shouldSkipFile(url: jsonlFile, state: state) {
                    Self.parseFile(url: jsonlFile, state: &state)
                    cache.files[key] = state
                }

                guard let sessionId = state.sessionId, state.inputTokens + state.outputTokens > 0 else {
                    continue
                }

                let currentTokens = state.inputTokens + state.outputTokens

                // Discover and parse subagent sessions
                let sessionDir = jsonlFile.deletingPathExtension()
                let subagentsDir = sessionDir.appendingPathComponent("subagents")
                var subagentItems = [SessionImportItem]()
                var subagentTotalTokens = 0
                var anySubagentChanged = false

                if fm.fileExists(atPath: subagentsDir.path) {
                    if let subFiles = try? fm.contentsOfDirectory(
                        at: subagentsDir,
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for subFile in subFiles where subFile.pathExtension == "jsonl" {
                            let subKey = subFile.path
                            var subState = cache.files[subKey] ?? ClaudeFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)

                            if !Self.shouldSkipFile(url: subFile, state: subState) {
                                Self.parseFile(url: subFile, state: &subState)
                                cache.files[subKey] = subState
                            }

                            guard subState.inputTokens + subState.outputTokens > 0 else {
                                continue
                            }
                            // Use filename as subagent ID — sessionId in JSONL is the parent's
                            let subSessionId = subFile.deletingPathExtension().lastPathComponent

                            let subTokens = subState.inputTokens + subState.outputTokens
                            subagentTotalTokens += subTokens

                            // Only include subagents whose tokens actually changed
                            guard subTokens != subState.lastUploadedTokens else { continue }

                            subagentItems.append(Self.buildImportItem(
                                state: subState, sessionId: subSessionId, parentSessionId: sessionId,
                                isSubagent: true, projectName: projectName,
                                subagentCount: 0, subagentTokens: 0,
                                includeDetails: SessionDetailsPreference.isEnabled()
                            ))
                            uploadedCacheKeys.append(subKey)
                        }
                    }
                }

                // Only upload main session if its tokens changed
                let mainChanged = currentTokens != state.lastUploadedTokens
                guard mainChanged || !subagentItems.isEmpty else { continue }

                if mainChanged {
                    allSessions.append(Self.buildImportItem(
                        state: state, sessionId: sessionId, parentSessionId: nil,
                        isSubagent: false, projectName: projectName,
                        subagentCount: subagentItems.count, subagentTokens: subagentTotalTokens,
                        includeDetails: SessionDetailsPreference.isEnabled()
                    ))
                    uploadedCacheKeys.append(key)
                }

                allSessions.append(contentsOf: subagentItems)
            }
        }

        if !allSessions.isEmpty, let apiKey {
            let success = await uploadSessions(allSessions, apiKey: apiKey)
            if success {
                for cacheKey in uploadedCacheKeys {
                    if let state = cache.files[cacheKey] {
                        cache.files[cacheKey]?.lastUploadedTokens = state.inputTokens + state.outputTokens
                    }
                }
            }
        }

        pruneOldEntries()
        cache.lastScanUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveCache()
    }

    // MARK: - File Change Detection

    nonisolated static func shouldSkipFile(url: URL, state: ClaudeFileState) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return true
        }
        let mtime = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        let size = attrs[.size] as? Int64 ?? 0
        return mtime == state.mtimeUnixMs && size == state.size
    }

    // MARK: - Incremental File Parsing

    nonisolated static func parseFile(url: URL, state: inout ClaudeFileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { handle.closeFile() }

        // If file was truncated/rewritten (smaller than where we left off), reset
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int64,
           state.parsedBytes > fileSize {
            state = ClaudeFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)
        }

        // Read from where we left off
        handle.seek(toFileOffset: UInt64(max(0, state.parsedBytes)))
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        // Map tool_use IDs to toolCalls index for error attribution
        var toolUseIdToIndex: [String: Int] = [:]

        var lineStart = data.startIndex
        for i in data.indices {
            guard data[i] == UInt8(ascii: "\n") else { continue }
            let lineData = data[lineStart..<i]
            lineStart = data.index(after: i)

            guard !lineData.isEmpty else { continue }
            let events = ClaudeJSONLParser.parseLine(Data(lineData))

            for parsed in events {
                switch parsed.kind {
                case .assistantUsage(let model, let input, let output, let cacheRead, let cacheCreation):
                    state.inputTokens += input
                    state.outputTokens += output
                    state.cacheReadTokens += cacheRead
                    state.cacheCreationTokens += cacheCreation
                    if let model {
                        state.primaryModel = model
                        var record = state.modelUsage[model] ?? ModelTokenRecord()
                        record.inputTokens += input
                        record.outputTokens += output
                        record.cacheReadTokens += cacheRead
                        record.cacheCreationTokens += cacheCreation
                        record.messageCount += 1
                        state.modelUsage[model] = record
                    }
                    state.executionTurns += 1

                case .toolUse(let id, let name, let filePath, let timestamp):
                    let record = ToolCallRecord(toolName: name, isError: false, filePath: filePath, timestamp: timestamp)
                    let idx = state.toolCalls.count
                    state.toolCalls.append(record)
                    state.toolCallCount += 1
                    if let id { toolUseIdToIndex[id] = idx }
                    if let filePath, ["Write", "Edit"].contains(name) {
                        state.filesModified.insert(filePath)
                    }

                case .toolResult(let toolUseId, let isError):
                    if isError {
                        state.toolErrorCount += 1
                        // Match to the specific tool call by ID
                        if let idx = toolUseIdToIndex[toolUseId] {
                            state.toolCalls[idx].isError = true
                        } else if let lastIdx = state.toolCalls.indices.last {
                            state.toolCalls[lastIdx].isError = true
                        }
                    }

                case .humanPrompt(let text, _):
                    if state.firstPrompt == nil {
                        state.firstPrompt = String(text.prefix(500))
                    }

                case .metadata(let sessionId, _, let timestamp, let gitBranch, let permissionMode):
                    if let sessionId, state.sessionId == nil {
                        state.sessionId = sessionId
                    }
                    if let timestamp, state.startedAt == nil {
                        state.startedAt = timestamp
                    }
                    if let gitBranch {
                        state.gitBranch = gitBranch
                    }
                    if permissionMode == "plan" {
                        state.planModeTurns += 1
                    }

                case .sessionTitle(let title):
                    state.sessionTitle = title
                }
            }
        }

        state.filesModifiedCount = state.filesModified.count
        // Cap tool_calls array to prevent unbounded cache growth
        if state.toolCalls.count > 500 {
            state.toolCalls = Array(state.toolCalls.suffix(500))
        }

        // Update file state
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            state.mtimeUnixMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
            state.size = attrs[.size] as? Int64 ?? 0
        }
        state.parsedBytes += Int64(lineStart)
    }

    // MARK: - Project Name Extraction

    nonisolated static func projectName(from dirName: String, username: String?) -> String {
        var name = dirName
        // Strip leading -Users-{username}- prefix
        if let username {
            let prefixes = ["-Users-\(username)-", "Users-\(username)-"]
            for prefix in prefixes {
                if name.hasPrefix(prefix) {
                    name = String(name.dropFirst(prefix.count))
                    break
                }
            }
        }
        // Convert remaining dashes to path separators for readability
        return name.isEmpty ? dirName : name
    }

    // MARK: - Import Item Builder

    nonisolated static func buildImportItem(
        state: ClaudeFileState, sessionId: String, parentSessionId: String?,
        isSubagent: Bool, projectName: String,
        subagentCount: Int, subagentTokens: Int,
        includeDetails: Bool = true
    ) -> SessionImportItem {
        // Without details (SessionDetailsPreference off), the prompt opening, title and file
        // paths stay on the Mac; tool names, counts and timings still go.
        let toolCalls: [ToolCallImportItem]? = state.toolCalls.isEmpty ? nil : state.toolCalls.map {
            ToolCallImportItem(tool_name: $0.toolName, is_error: $0.isError,
                               file_path: includeDetails ? $0.filePath : nil, timestamp: $0.timestamp)
        }
        let modelUsage: [ModelUsageImportItem]? = state.modelUsage.isEmpty ? nil : state.modelUsage.map { (model, record) in
            ModelUsageImportItem(
                model: model,
                input_tokens: record.inputTokens, output_tokens: record.outputTokens,
                cache_read_tokens: record.cacheReadTokens, cache_creation_tokens: record.cacheCreationTokens,
                message_count: record.messageCount
            )
        }
        return SessionImportItem(
            session_id: sessionId,
            parent_session_id: parentSessionId,
            is_subagent: isSubagent,
            project_path: projectName,
            started_at: state.startedAt,
            input_tokens: state.inputTokens,
            output_tokens: state.outputTokens,
            cache_read_tokens: state.cacheReadTokens,
            cache_creation_tokens: state.cacheCreationTokens,
            subagent_count: subagentCount,
            subagent_tokens: subagentTokens,
            first_prompt: includeDetails ? state.firstPrompt.map { String($0.prefix(500)) } : nil,
            session_title: includeDetails ? state.sessionTitle : nil,
            git_branch: state.gitBranch,
            primary_model: state.primaryModel,
            tool_call_count: state.toolCallCount,
            tool_error_count: state.toolErrorCount,
            files_modified_count: state.filesModifiedCount,
            plan_mode_turns: state.planModeTurns,
            execution_turns: state.executionTurns,
            tool_calls: toolCalls,
            model_usage: modelUsage
        )
    }

    // MARK: - API Upload

    @discardableResult
    private func uploadSessions(_ sessions: [SessionImportItem], apiKey: String) async -> Bool {
        if clientPolicy.current.level == .block {
            DebugLog.shared.log("[ClaudeScanner] Skipping upload: client policy is block")
            return false
        }
        var allSucceeded = true
        // Send in batches of 500
        for batchStart in stride(from: 0, to: sessions.count, by: 500) {
            let batchEnd = min(batchStart + 500, sessions.count)
            let batch = Array(sessions[batchStart..<batchEnd])
            let payload = SessionImportPayload(sessions: batch)

            guard let body = try? JSONEncoder().encode(payload) else {
                DebugLog.shared.log("[ClaudeScanner] Failed to encode payload")
                continue
            }

            guard let url = URL(string: "\(ingestURL)/v1/import/sessions") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = body

            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                    let imported = result["imported_sessions"] as? Int ?? 0
                    DebugLog.shared.log("[ClaudeScanner] Uploaded batch — HTTP \(status), imported=\(imported)")
                } else {
                    DebugLog.shared.log("[ClaudeScanner] Uploaded batch — HTTP \(status)")
                }
            } catch {
                DebugLog.shared.log("[ClaudeScanner] Upload failed: \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    // MARK: - Cache Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cachePath),
              let decoded = try? JSONDecoder().decode(ClaudeScannerCache.self, from: data) else {
            cache = ClaudeScannerCache()
            return
        }
        cache = decoded
    }

    private func saveCache() {
        let dir = cachePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let tmp = cachePath.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(cachePath, withItemAt: tmp)
        } catch {
            try? FileManager.default.moveItem(at: tmp, to: cachePath)
        }
    }

    private func pruneOldEntries() {
        // Prune by file existence, NOT by age. Age-based pruning evicted
        // entries for >30d-old files that still exist on disk, so every scan
        // re-parsed them from byte 0 (lastUploadedTokens reset to 0) and
        // re-uploaded them — an infinite re-upload loop for old sessions.
        let fm = FileManager.default
        cache.files = cache.files.filter { fm.fileExists(atPath: $0.key) }
    }

    // MARK: - Timer Scheduling

    private func scheduleNext() {
        timer?.invalidate()
        guard !activityMonitor.isSleeping else { return }
        let interval = activityMonitor.isIdle() ? idleInterval : activeInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scanAndScheduleNext()
            }
        }
    }
}
