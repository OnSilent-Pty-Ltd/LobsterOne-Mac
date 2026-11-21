import CoreServices
import Foundation

/// Watches `~/.claude` for two things: a crew member's charter or notebook changing, and a crew
/// member's run being written to. Reads no transcript content; only which agent a run belongs to.
@MainActor
final class CrewWatcher {
    private var stream: FSEventStreamRef?
    private var pendingCheck: Task<Void, Never>?
    private var quietTimer: Timer?
    /// Transcript path to the agent it belongs to; nil once known not to be a subagent run.
    private var agents: [String: String?] = [:]
    private let root: URL
    private let monitor: TeamMonitor

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, monitor: TeamMonitor) {
        root = home.appendingPathComponent(".claude")
        self.monitor = monitor
    }

    func start() {
        stop()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<CrewWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            MainActor.assumeIsolated { watcher.filesChanged(Array(changed)) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        else {
            DebugLog.shared.log("Crew: could not watch \(root.path)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        pendingCheck?.cancel()
        quietTimer?.invalidate()
        quietTimer = nil
    }

    func filesChanged(_ paths: [String], now: Date = Date()) {
        var crewFilesChanged = false
        for path in paths {
            switch Self.classify(path) {
            case .crewFile: crewFilesChanged = true
            case .run: noteRun(path, now: now)
            case .other: break
            }
        }
        if crewFilesChanged { scheduleCheck() }
    }

    enum Change: Equatable { case crewFile, run, other }

    /// A charter or notebook, a subagent's transcript, or something that is none of our business.
    nonisolated static func classify(_ path: String) -> Change {
        if path.contains("/.claude/agents/") || path.contains("/.claude/agent-memory/") {
            return path.hasSuffix(".md") ? .crewFile : .other
        }
        if path.contains("/.claude/projects/"), path.contains("/subagents/"), path.hasSuffix(".jsonl") { return .run }
        return .other
    }

    /// Several saves in a row make one check.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.monitor.checkCrew()
        }
    }

    private func noteRun(_ path: String, now: Date) {
        let agent: String?
        if let known = agents[path] {
            agent = known
        } else {
            agent = Self.agentType(forTranscript: path)
            // A run's meta file can land a moment after its first line; ask again next time if absent.
            if agent != nil { agents[path] = agent }
            if agents.count > 2000 { agents.removeAll() }
        }
        guard let agent, monitor.report.notes[agent] != nil else { return }
        monitor.sawActivity(agent: agent, at: now)
        if quietTimer == nil {
            quietTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func tick() {
        monitor.updateWorking(at: Date())
        if monitor.working.isEmpty {
            quietTimer?.invalidate()
            quietTimer = nil
        }
    }

    nonisolated static func agentType(forTranscript path: String) -> String? {
        let meta = String(path.dropLast(".jsonl".count)) + ".meta.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: meta)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["agentType"] as? String
    }
}
