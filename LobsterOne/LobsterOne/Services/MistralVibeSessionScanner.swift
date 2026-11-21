import Combine
import Foundation

/// Per-folder cumulative state tracked across scans for one Vibe session.
struct VibeFolderState: Codable {
    var metaMtimeMs: Int64 = 0
    var messagesParsedBytes: Int64 = 0
    var lastPromptTokens: Int = 0
    var lastCompletionTokens: Int = 0
    var lastCost: Double = 0
    var sessionId: String?
    var model: String?
    var emittedSession: Bool = false
}

/// Persisted scanner cache, keyed by session-folder path.
struct VibeScannerCache: Codable {
    var lastScanUnixMs: Int64 = 0
    var folders: [String: VibeFolderState] = [:]
}

/// Result of processing one folder: zero or one already-deltaed metric.
struct VibeParseResult {
    var deltas: [VibeMetricDelta] = []
}

/// Scans `~/.vibe/sessions/session_*/` folders, computes per-folder cumulative
/// deltas from `meta.json` (+ LoC from `messages.jsonl`), and forwards them to
/// the ingest endpoint as OTLP/JSON DELTA metrics. Mirrors `CodexSessionScanner`.
@MainActor
final class MistralVibeSessionScanner: ObservableObject {
    /// Caller must ensure the shared ActivityMonitor is started before calling start(apiKey:).
    let activeInterval: TimeInterval = Constants.scannerActiveInterval
    let idleInterval: TimeInterval = Constants.scannerIdleInterval

    private let activityMonitor: ActivityMonitor
    private let clientPolicy: ClientPolicyService
    private let ingestURL: String
    private let sessionsDir: URL
    private let cachePath: URL

    private var cache = VibeScannerCache()
    private var apiKey: String?
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        clientPolicy: ClientPolicyService? = nil,
        ingestURL: String = Constants.ingestURL,
        sessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/sessions"),
        cachePath: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LobsterOne/mistral-vibe-scanner-cache.json")
    ) {
        self.activityMonitor = activityMonitor
        self.clientPolicy = clientPolicy ?? ClientPolicyService()
        self.ingestURL = ingestURL
        self.sessionsDir = sessionsDir
        self.cachePath = cachePath
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

    func forceRescan() async {
        if let apiKey { await resetServerMetrics(apiKey: apiKey) }
        cache = VibeScannerCache()
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
            DebugLog.shared.log("[Vibe] server reset — HTTP \(status)")
        } catch {
            DebugLog.shared.log("[Vibe] server reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scan Cycle

    private func scanAndScheduleNext() async {
        await scan()
        scheduleNext()
    }

    private func scan() async {
        let folders = Self.discoverSessionFolders(sessionsDir: sessionsDir)
        var allDeltas: [VibeMetricDelta] = []
        var pendingStates = [String: VibeFolderState]()

        for folder in folders {
            let key = folder.path
            var state = cache.folders[key] ?? VibeFolderState()
            let result = Self.processFolder(url: folder, state: &state)
            pendingStates[key] = state
            allDeltas.append(contentsOf: result.deltas)
        }

        let hasEvents = !allDeltas.isEmpty
        var forwardSucceeded = false
        if hasEvents, let apiKey {
            forwardSucceeded = await forward(deltas: allDeltas, apiKey: apiKey)
        }
        if Self.shouldCommitStates(hasEvents: hasEvents, forwardSucceeded: forwardSucceeded) {
            for (key, state) in pendingStates { cache.folders[key] = state }
        }

        pruneOldFolders()
        cache.lastScanUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveCache()
    }

    // MARK: - Folder Discovery

    nonisolated static func discoverSessionFolders(sessionsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { url in
                var isDir: ObjCBool = false
                let metaPath = url.appendingPathComponent("meta.json").path
                return fm.fileExists(atPath: url.path, isDirectory: &isDir)
                    && isDir.boolValue
                    && fm.fileExists(atPath: metaPath)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Incremental Per-Folder Delta

    nonisolated static func processFolder(url: URL, state: inout VibeFolderState) -> VibeParseResult {
        let fm = FileManager.default
        let metaURL = url.appendingPathComponent("meta.json")
        let messagesURL = url.appendingPathComponent("messages.jsonl")

        let metaAttrs = try? fm.attributesOfItem(atPath: metaURL.path)
        let metaMtime = Int64(((metaAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        let messagesSize = Int64((try? fm.attributesOfItem(atPath: messagesURL.path))?[.size] as? Int64 ?? 0)

        let metaUnchanged = metaMtime == state.metaMtimeMs && state.metaMtimeMs != 0
        let noNewMessages = messagesSize <= state.messagesParsedBytes
        if metaUnchanged && noNewMessages { return VibeParseResult() }

        guard let metaData = try? Data(contentsOf: metaURL),
              let stats = VibeMetaParser.parse(metaData) else {
            return VibeParseResult()
        }

        let isNewSession = !state.emittedSession
        let inputDelta = max(0, stats.promptTokens - state.lastPromptTokens)
        let outputDelta = max(0, stats.completionTokens - state.lastCompletionTokens)
        let costDelta = max(0, stats.cost - state.lastCost)

        var added = 0, removed = 0
        if let handle = try? FileHandle(forReadingFrom: messagesURL) {
            defer { handle.closeFile() }
            handle.seek(toFileOffset: UInt64(state.messagesParsedBytes))
            let newData = handle.readDataToEndOfFile()
            if !newData.isEmpty {
                if let lastNewline = newData.lastIndex(of: UInt8(ascii: "\n")) {
                    let completeChunk = newData[newData.startIndex...lastNewline]
                    let edits = VibeMessageParser.parseEdits(Data(completeChunk))
                    added = edits.added
                    removed = edits.removed
                    state.messagesParsedBytes += Int64(completeChunk.count)
                }
            }
        }

        state.metaMtimeMs = metaMtime
        state.lastPromptTokens = stats.promptTokens
        state.lastCompletionTokens = stats.completionTokens
        state.lastCost = stats.cost
        state.sessionId = stats.sessionId
        state.model = stats.model
        state.emittedSession = true

        let hasMetric = inputDelta != 0 || outputDelta != 0 || costDelta != 0
            || added != 0 || removed != 0 || isNewSession
        guard hasMetric else { return VibeParseResult() }

        let delta = VibeMetricDelta(
            sessionId: stats.sessionId,
            model: stats.model,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            inputTokens: inputDelta,
            outputTokens: outputDelta,
            cost: costDelta,
            locAdded: added,
            locRemoved: removed,
            isNewSession: isNewSession)

        return VibeParseResult(deltas: [delta])
    }

    // MARK: - OTel Forwarding

    /// See CodexSessionScanner: only advance the cursor when nothing was sent or the
    /// send was accepted, so a failed forward doesn't silently drop unsent deltas.
    nonisolated static func shouldCommitStates(hasEvents: Bool, forwardSucceeded: Bool) -> Bool {
        !hasEvents || forwardSucceeded
    }

    @discardableResult
    private func forward(deltas: [VibeMetricDelta], apiKey: String) async -> Bool {
        if clientPolicy.current.level == .block {
            DebugLog.shared.log("[Vibe] Skipping forward: client policy is block")
            return false
        }
        let payload = VibeOTelPayloadBuilder.buildMetricsPayload(deltas: deltas)
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "\(ingestURL)/v1/metrics") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.shared.log("[Vibe] Forwarded \(deltas.count) deltas — HTTP \(status)")
            return (200..<300).contains(status)
        } catch {
            DebugLog.shared.log("[Vibe] Forward failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cache Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cachePath),
              let decoded = try? JSONDecoder().decode(VibeScannerCache.self, from: data) else {
            cache = VibeScannerCache()
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

    private func pruneOldFolders() {
        cache.folders = cache.folders.filter { FileManager.default.fileExists(atPath: $0.key) }
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
