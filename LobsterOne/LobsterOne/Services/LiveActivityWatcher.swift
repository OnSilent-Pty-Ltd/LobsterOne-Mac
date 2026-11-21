import CoreServices
import Foundation

/// Watches Claude Code's and Codex's session logs as they are written and announces each
/// model response the moment it lands, so the screensaver can react to work as it happens
/// instead of to a five-minute average.
///
/// Announcements are distributed notifications named `ActivityEvent.notification`, carrying
/// only a token count, the tool's name and what kind of response it was. Any app of this user can observe them, so they
/// must never carry prompt or response content.
///
/// Covers this Mac only. Work on other machines still reaches the screensaver through the
/// polled totals.
@MainActor
final class LiveActivityWatcher {
    private var stream: FSEventStreamRef?
    private var files: [String: LogTail] = [:]
    private var seenClaudeMessages = RecentSet(capacity: 4000)
    /// Codex logs a turn's tool calls before the turn's token count, per log file.
    private var codexKinds: [String: ActivityEvent.Kind] = [:]
    private let roots: [URL]
    private let post: (ActivityEvent) -> Void

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         post: @escaping (ActivityEvent) -> Void = ActivityEvent.broadcast) {
        roots = [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".codex/sessions")]
        self.post = post
    }

    func start() {
        stop()
        let paths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        // Start every recent log at its end, so the backlog is not replayed as live activity.
        for root in paths { primeOffsets(under: URL(fileURLWithPath: root)) }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LiveActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            MainActor.assumeIsolated { watcher.filesChanged(Array(changed)) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        else {
            DebugLog.shared.log("Live activity: could not watch session logs")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        DebugLog.shared.log("Live activity: watching \(paths.count) log folder(s), \(files.count) recent log(s)")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func primeOffsets(under root: URL) {
        let dayAgo = Date().addingTimeInterval(-86_400)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = values?.contentModificationDate, modified > dayAgo else { continue }
            files[url.path] = LogTail(offset: UInt64(values?.fileSize ?? 0))
        }
    }

    private func filesChanged(_ paths: [String]) {
        for path in Set(paths) where path.hasSuffix(".jsonl") {
            // A log we have not seen was created after we started: read it from the top.
            var tail = files[path] ?? LogTail(offset: 0)
            let lines = tail.readNewLines(path: path)
            files[path] = tail
            for line in lines {
                if let kind = ActivityEvent.codexCallKind(line: line) {
                    // An edit outranks a plain tool call within one turn.
                    if codexKinds[path] != .edit { codexKinds[path] = kind }
                    continue
                }
                guard var event = ActivityEvent.parse(line: line, seenClaudeMessages: &seenClaudeMessages) else { continue }
                if event.source == .codex {
                    event.kind = codexKinds.removeValue(forKey: path) ?? .answer
                }
                post(event)
            }
        }
    }
}

/// One model response, as announced to the screensaver.
struct ActivityEvent: Equatable {
    static let notification = Notification.Name("ai.lobsterone.activity")

    enum Source: String {
        case claude, codex
    }

    /// What the response did, for colour: a plain answer, a tool call, or a file edit.
    enum Kind: String {
        case answer, tool, edit
    }

    /// Input plus output, not counting cache reads or writes, to match the headline figure.
    let tokens: Int
    let source: Source
    var kind: Kind = .answer

    /// Claude Code's and Codex's tools that change files.
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"]

    static func broadcast(_ event: ActivityEvent) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil,
            userInfo: ["tokens": event.tokens, "source": event.source.rawValue, "kind": event.kind.rawValue],
            deliverImmediately: true)
    }

    /// Reads one log line. Claude Code writes a response as several lines that share a
    /// message id, so each id counts once.
    /// A Codex tool call line, which carries no tokens itself: the turn's token count follows.
    static func codexCallKind(line: Data) -> Kind? {
        guard line.range(of: Data("_call\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              ["function_call", "custom_tool_call", "local_shell_call"].contains(type) else { return nil }
        return editTools.contains(payload["name"] as? String ?? "") ? .edit : .tool
    }

    static func parse(line: Data, seenClaudeMessages: inout RecentSet) -> ActivityEvent? {
        // Most lines are tool output or prompts, some of them large; skip those unparsed.
        guard line.range(of: Data("usage".utf8)) != nil else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }

        if object["type"] as? String == "assistant",
           let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            if let id = message["id"] as? String {
                guard seenClaudeMessages.insert(id) else { return nil }
            }
            let tokens = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
            let tools = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "tool_use" }
                .compactMap { $0["name"] as? String }
            let kind: Kind = tools.contains(where: editTools.contains) ? .edit : (tools.isEmpty ? .answer : .tool)
            return ActivityEvent(tokens: tokens, source: .claude, kind: kind)
        }

        if object["type"] as? String == "event_msg",
           let payload = object["payload"] as? [String: Any],
           payload["type"] as? String == "token_count",
           let info = payload["info"] as? [String: Any],
           let usage = info["last_token_usage"] as? [String: Any] {
            // Codex counts cached input inside input_tokens.
            let input = (usage["input_tokens"] as? Int ?? 0) - (usage["cached_input_tokens"] as? Int ?? 0)
            let tokens = max(0, input) + (usage["output_tokens"] as? Int ?? 0)
            return ActivityEvent(tokens: tokens, source: .codex)
        }
        return nil
    }
}

/// Where we are in one growing log file. Only whole lines are consumed; a half-written last
/// line waits for the next change.
struct LogTail {
    var offset: UInt64

    mutating func readNewLines(path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Rewritten or truncated: start again from the top.
        if size < offset { offset = 0 }
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)) else { return [] }
        let (lines, consumed) = Self.completeLines(in: data)
        offset += UInt64(consumed)
        return lines
    }

    static func completeLines(in data: Data) -> (lines: [Data], consumed: Int) {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            if index > start { lines.append(data[start..<index]) }
            start = data.index(after: index)
        }
        return (lines, start - data.startIndex)
    }
}

/// A set that forgets its oldest entries past a fixed size.
struct RecentSet {
    let capacity: Int
    private var members = Set<String>()
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// False if already present.
    mutating func insert(_ value: String) -> Bool {
        guard members.insert(value).inserted else { return false }
        order.append(value)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}
