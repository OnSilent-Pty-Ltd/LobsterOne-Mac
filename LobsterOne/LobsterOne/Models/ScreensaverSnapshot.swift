import Foundation

/// What the menu bar app hands to the screensaver: a small file the app rewrites after each
/// poll and the screensaver reads. The screensaver runs inside Apple's sandboxed host, has no
/// credentials and makes no network calls, so this file is its only source of data.
///
/// Foundation only, on purpose: `ScreenSaver/build.sh` compiles this same file into the
/// screensaver so both sides share one definition of the format.
struct ScreensaverSnapshot: Codable, Equatable {
    /// Bump when a change would mislead an older reader. Readers ignore files they don't know.
    static let currentVersion = 1

    var version: Int = ScreensaverSnapshot.currentVersion
    /// When the app last heard from the backend (or last failed to, if `isOffline`).
    var updatedAt: Date
    /// Same figure as the menu bar.
    var tokens: Int
    var percentUsed: Double
    /// False when `percentUsed` is the backend's estimate, shown with a "~" in the app.
    var isRealQuota: Bool
    var plan: String
    var isOffline: Bool
    /// Recent burn rate as of `updatedAt`. Only as fresh as the app's last poll.
    var tokensPerMinute: Double
    /// End of the current 5-hour window, when known.
    var resetsAt: Date?
    /// Oldest to newest, as the server ordered them. No cost figures: a screensaver is
    /// visible to anyone walking past.
    var sevenDay: [Day]
    /// Which design to show. Nil in files from before there was a choice: the den.
    var style: ScreensaverStyle?
    /// Today's tokens per connected tool, for the dashboard.
    var sources: [Source]?
    /// Today's board, only fetched while the leaderboard design is chosen.
    var leaderboard: Leaderboard?

    struct Day: Codable, Equatable {
        var date: String   // "yyyy-MM-dd"
        var tokens: Int
    }

    struct Source: Codable, Equatable {
        var name: String
        var tokens: Int
    }

    struct Leaderboard: Codable, Equatable {
        /// What is ranked, for the heading, e.g. "lines shipped".
        var metric: String
        var fetchedAt: Date
        var yourRank: Int?
        var yourValue: Double?
        var totalUsers: Int
        /// The top of the board, plus your row when you are further down.
        var entries: [Entry]

        struct Entry: Codable, Equatable {
            var rank: Int
            var name: String
            var value: Double
            var isYou: Bool
        }
    }

    // MARK: - File

    /// `~/Library/Application Support/LobsterOne/screensaver.json`. Takes the home directory
    /// explicitly because inside the screensaver host `NSHomeDirectory()` is a container.
    static func fileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/LobsterOne/screensaver.json")
    }

    /// The user's real home directory, sandboxed or not.
    static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Nil for anything unreadable or written by a newer format.
    static func decode(_ data: Data) -> ScreensaverSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(ScreensaverSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }
}

/// The screensaver's designs. Chosen in the app's Settings, carried to the saver in the snapshot.
enum ScreensaverStyle: String, Codable, CaseIterable {
    // Picker order. Raw values are what the snapshot stores, so never rename them.
    case matrix, den, dashboard, leaderboard

    /// What a new user gets, and what a snapshot without a style means.
    static let standard: ScreensaverStyle = .matrix

    var title: String {
        switch self {
        case .den: "Garry's den"
        case .dashboard: "Dashboard"
        case .leaderboard: "Leaderboard"
        case .matrix: "Token rain"
        }
    }

    var summary: String {
        switch self {
        case .den: "Garry hauls a shell for every response; the pile grows when you outpace him."
        case .dashboard: "Your menu bar numbers full screen, with a live feed."
        case .leaderboard: "Where you rank today on lines shipped."
        case .matrix: "Each response falls as a column of light; colour tells answers, tool calls and edits apart."
        }
    }
}
