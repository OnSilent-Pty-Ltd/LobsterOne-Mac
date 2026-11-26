import Combine
import Foundation

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog(file: DebugLogFile(directory: DebugLogFile.defaultDirectory))

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    @Published var entries: [Entry] = []
    /// Lines kept in memory for the Diagnostics view; older ones drop off.
    /// The file on disk keeps far more (see DebugLogFile).
    static let capacity = 300
    private let maxEntries = DebugLog.capacity

    /// Nil in tests, so they never touch the real log.
    private let file: DebugLogFile?

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(file: DebugLogFile? = nil) {
        self.file = file
        file?.append("--- \(AppVersion.userAgent), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), started", at: Date())
    }

    /// Where the full log lives, for "Show log file".
    var fileURL: URL? { file?.url }

    func log(_ message: String) {
        let entry = Entry(timestamp: Date(), message: Self.redact(message))
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        file?.append(entry.message, at: entry.timestamp)
    }

    var formatted: String {
        entries.map { "[\(formatter.string(from: $0.timestamp))] \($0.message)" }.joined(separator: "\n")
    }

    // MARK: - Redaction

    /// The log goes to disk and gets pasted into issues, so tokens never reach it,
    /// even if a caller slips one in by mistake.
    private static let secretPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"sk-ant-[A-Za-z0-9_\-]+"#), "sk-ant-[redacted]"),
        (try! NSRegularExpression(pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/=\-]+"#), "Bearer [redacted]"),
        // Full LobsterOne keys; the short prefixes Diagnostics shows stay readable.
        (try! NSRegularExpression(pattern: #"rc_[A-Za-z0-9]{16,}"#), "rc_[redacted]"),
    ]

    static func redact(_ message: String) -> String {
        var result = message
        for (pattern, replacement) in secretPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}

/// Appends log lines to `~/Library/Logs/LobsterOne/debug.log`, so a problem that
/// started hours ago (or before a restart) can still be read. Rotates at `maxBytes`,
/// keeping `backups` older files (debug.1.log, debug.2.log). Writes happen on a
/// serial queue, off the main thread.
final class DebugLogFile: @unchecked Sendable {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LobsterOne", isDirectory: true)
    }

    let directory: URL
    let url: URL
    private let maxBytes: Int
    private let backups: Int
    private let queue = DispatchQueue(label: "com.lobsterone.debuglog", qos: .utility)

    // Touched only on `queue`.
    private var handle: FileHandle?
    private var size = 0
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    init(directory: URL, maxBytes: Int = 2_000_000, backups: Int = 2) {
        self.directory = directory
        self.url = directory.appendingPathComponent("debug.log")
        self.maxBytes = maxBytes
        self.backups = backups
    }

    func append(_ message: String, at date: Date) {
        queue.async { [self] in
            let line = "\(stamp.string(from: date)) \(message)\n"
            write(Data(line.utf8))
        }
    }

    /// Blocks until queued writes are on disk. For tests.
    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        if handle == nil { open() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            close()
            return
        }
        if size >= maxBytes { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func close() {
        try? handle?.close()
        handle = nil
        size = 0
    }

    private func backupURL(_ n: Int) -> URL {
        directory.appendingPathComponent("debug.\(n).log")
    }

    private func rotate() {
        close()
        let fm = FileManager.default
        if backups > 0 {
            try? fm.removeItem(at: backupURL(backups))
            for n in stride(from: backups - 1, through: 1, by: -1) {
                try? fm.moveItem(at: backupURL(n), to: backupURL(n + 1))
            }
            try? fm.moveItem(at: url, to: backupURL(1))
        } else {
            try? fm.removeItem(at: url)
        }
        // Start the new file now, so "Log file" in Diagnostics always finds one.
        open()
    }
}
