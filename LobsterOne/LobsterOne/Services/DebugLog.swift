import Combine
import Foundation

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    @Published var entries: [Entry] = []
    /// Lines kept in memory; older ones drop off.
    static let capacity = 50
    private let maxEntries = DebugLog.capacity

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        entries.append(Entry(timestamp: Date(), message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    var formatted: String {
        entries.map { "[\(formatter.string(from: $0.timestamp))] \($0.message)" }.joined(separator: "\n")
    }
}
