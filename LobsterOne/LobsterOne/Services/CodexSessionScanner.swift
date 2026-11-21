import Combine
import Foundation

@MainActor
final class CodexSessionScanner: ObservableObject {
    /// Caller must ensure the shared ActivityMonitor is started before calling start(apiKey:).
    let activeInterval: TimeInterval = Constants.scannerActiveInterval
    let idleInterval: TimeInterval = Constants.scannerIdleInterval

    private let activityMonitor: ActivityMonitor
    private let clientPolicy: ClientPolicyService
    private let ingestURL: String
    private let codexHome: URL
    private let cachePath: URL
    private let apiClient: APIClient

    private var apiKey: String?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var cache = CodexScannerCache()

    init(
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        clientPolicy: ClientPolicyService? = nil,
        ingestURL: String = Constants.ingestURL,
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        cachePath: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LobsterOne/codex-scanner-cache.json"),
        apiClient: APIClient = APIClient()
    ) {
        self.activityMonitor = activityMonitor
        self.clientPolicy = clientPolicy ?? ClientPolicyService()
        self.ingestURL = ingestURL
        self.codexHome = codexHome
        self.cachePath = cachePath
        self.apiClient = apiClient
    }

    func start(apiKey: String) {
        self.apiKey = apiKey
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

    /// Clears server + local state, then re-imports every on-disk session under the
    /// current key. Resets the server first because Codex metrics are summed deltas —
    /// re-sending without a reset would double-count.
    func forceRescan() async {
        if let apiKey { await resetServerMetrics(apiKey: apiKey) }
        cache = CodexScannerCache()
        saveCache()
        await scan()
    }

    private func resetServerMetrics(apiKey: String) async {
        guard let url = URL(string: "\(ingestURL)/v1/instance/reset") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.shared.log("[Scanner] Codex server reset — HTTP \(status)")
        } catch {
            DebugLog.shared.log("[Scanner] Codex server reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scan Cycle

    private func scanAndScheduleNext() async {
        await scan()
        scheduleNext()
    }

    private func scan() async {
        let files = Self.discoverSessionFiles(codexHome: codexHome)

        var seenSessionIds = Set<String>()
        var allEvents = [TokenEvent]()
        var allLines = [LineEvent]()
        var newestRateLimits: CodexRateLimits?
        var newestRateLimitsTimestamp: String?
        var pendingStates = [String: CodexFileState]()

        for file in files {
            let key = file.path
            var state = cache.files[key] ?? CodexFileState(mtimeUnixMs: 0, size: 0, parsedBytes: 0)

            if Self.shouldSkipFile(url: file, state: state) {
                if let sid = state.sessionId { seenSessionIds.insert(sid) }
                continue
            }

            let parsed = Self.parseFile(url: file, state: &state)

            if let sid = state.sessionId {
                if seenSessionIds.contains(sid) { continue }
                seenSessionIds.insert(sid)
            }

            allEvents.append(contentsOf: parsed.tokens)
            allLines.append(contentsOf: parsed.lines)
            pendingStates[key] = state

            if let ts = state.lastRateLimitsTimestamp, let rl = state.lastRateLimits,
               newestRateLimitsTimestamp == nil || ts > newestRateLimitsTimestamp! {
                newestRateLimits = rl
                newestRateLimitsTimestamp = ts
            }
        }

        let hasEvents = !allEvents.isEmpty || !allLines.isEmpty
        var forwardSucceeded = false
        if hasEvents, let apiKey {
            forwardSucceeded = await forwardEvents(tokens: allEvents, lines: allLines, apiKey: apiKey)
        }
        if Self.shouldCommitStates(hasEvents: hasEvents, forwardSucceeded: forwardSucceeded) {
            for (key, state) in pendingStates { cache.files[key] = state }
        }

        if let limits = newestRateLimits, let apiKey, clientPolicy.current.level != .block {
            let payload = CodexQuotaSnapshotPayload(from: limits)
            do {
                try await apiClient.postCodexQuotaSnapshot(payload, apiKey: apiKey)
                DebugLog.shared.log("[Scanner] Codex rate-limit snapshot posted (primary=\(limits.primary?.usedPercent.description ?? "n/a")%)")
            } catch {
                DebugLog.shared.log("[Scanner] Codex snapshot post failed: \(error.localizedDescription)")
            }
        }

        pruneOldEntries()
        cache.lastScanUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveCache()
    }

    // MARK: - File Discovery

    nonisolated static func discoverSessionFiles(codexHome: URL) -> [URL] {
        let fm = FileManager.default
        let cal = Calendar.current
        let now = Date()
        let today = cal.dateComponents([.year, .month, .day], from: now)
        let yesterday = cal.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-86400))

        var result = [URL]()
        for dc in [today, yesterday] {
            guard let y = dc.year, let m = dc.month, let d = dc.day else { continue }
            let dir = codexHome
                .appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            result.append(contentsOf: urls.filter { $0.pathExtension == "jsonl" })
        }
        return result
    }

    // MARK: - File Change Detection

    nonisolated static func shouldSkipFile(url: URL, state: CodexFileState) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return true
        }
        let mtime = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        let size = attrs[.size] as? Int64 ?? 0
        return mtime == state.mtimeUnixMs && size == state.size
    }

    // MARK: - Incremental File Parsing

    nonisolated static func parseFile(url: URL, state: inout CodexFileState) -> CodexParseResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return CodexParseResult() }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: UInt64(state.parsedBytes))
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return CodexParseResult() }

        var events = [TokenEvent]()
        var lineEvents = [LineEvent]()
        var currentModel = state.lastModel
        var currentSessionId = state.sessionId
        var lastTotals = state.lastTotals
        var lastRateLimits = state.lastRateLimits
        var lastRateLimitsTimestamp = state.lastRateLimitsTimestamp
        var historyMode = state.historyMode

        // Split by newlines
        var lineStart = data.startIndex
        for i in data.indices {
            guard data[i] == UInt8(ascii: "\n") else { continue }
            let lineData = data[lineStart..<i]
            lineStart = data.index(after: i)

            guard !lineData.isEmpty else { continue }
            guard let event = CodexJSONLParser.parseLine(Data(lineData)) else { continue }

            switch event {
            case .sessionMeta(let sessionId, let mode):
                currentSessionId = sessionId
                historyMode = mode
            case .turnContext(let model):
                currentModel = model
            case .tokenCount(let timestamp, let totals):
                let delta = totals.delta(from: lastTotals)
                lastTotals = totals
                if !delta.isZero, let model = currentModel, let sid = currentSessionId {
                    events.append(TokenEvent(
                        timestamp: timestamp,
                        model: model,
                        sessionId: sid,
                        delta: delta
                    ))
                }
            case .rateLimits(let timestamp, let limits):
                if lastRateLimitsTimestamp == nil || timestamp > lastRateLimitsTimestamp! {
                    lastRateLimits = limits
                    lastRateLimitsTimestamp = timestamp
                }
            // Paginated sessions log an edit as both the raw tool call and a FileChange
            // item, so count exactly one source per session to avoid double counting.
            case .patchApplied(let timestamp, let added, let removed):
                if historyMode != "paginated", let model = currentModel, let sid = currentSessionId {
                    lineEvents.append(LineEvent(
                        timestamp: timestamp,
                        model: model,
                        sessionId: sid,
                        added: added,
                        removed: removed
                    ))
                }
            case .fileChangeApplied(let timestamp, let added, let removed):
                if historyMode == "paginated", let model = currentModel, let sid = currentSessionId {
                    lineEvents.append(LineEvent(
                        timestamp: timestamp,
                        model: model,
                        sessionId: sid,
                        added: added,
                        removed: removed
                    ))
                }
            }
        }

        // Update state
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            state.mtimeUnixMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
            state.size = attrs[.size] as? Int64 ?? 0
        }
        state.parsedBytes += Int64(lineStart)
        state.sessionId = currentSessionId
        state.lastModel = currentModel
        state.lastTotals = lastTotals
        state.lastRateLimits = lastRateLimits
        state.lastRateLimitsTimestamp = lastRateLimitsTimestamp
        state.historyMode = historyMode

        return CodexParseResult(tokens: events, lines: lineEvents)
    }

    // MARK: - OTel Forwarding

    /// Whether to persist this scan's advanced parse cursor. Only advance when there
    /// was nothing to send, or the send was accepted — otherwise a failed forward
    /// (403/network/blocked) would silently drop the unsent data.
    nonisolated static func shouldCommitStates(hasEvents: Bool, forwardSucceeded: Bool) -> Bool {
        !hasEvents || forwardSucceeded
    }

    private func forwardEvents(tokens: [TokenEvent], lines: [LineEvent], apiKey: String) async -> Bool {
        if clientPolicy.current.level == .block {
            DebugLog.shared.log("[Scanner] Skipping forward: client policy is block")
            return false
        }
        let payload = OTelPayloadBuilder.buildMetricsPayload(events: tokens, lineEvents: lines)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            DebugLog.shared.log("[Scanner] Failed to serialize OTel payload")
            return false
        }
        guard let url = URL(string: "\(ingestURL)/v1/metrics") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.shared.log("[Scanner] Forwarded \(tokens.count) token + \(lines.count) line events — HTTP \(status)")
            return (200..<300).contains(status)
        } catch {
            DebugLog.shared.log("[Scanner] Forward failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cache Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cachePath),
              let decoded = try? JSONDecoder().decode(CodexScannerCache.self, from: data) else {
            cache = CodexScannerCache()
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
            // If replace fails (e.g. cachePath doesn't exist yet), just move
            try? FileManager.default.moveItem(at: tmp, to: cachePath)
        }
    }

    private func pruneOldEntries() {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - (7 * 24 * 3600 * 1000)
        cache.files = cache.files.filter { $0.value.mtimeUnixMs >= cutoff }
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
