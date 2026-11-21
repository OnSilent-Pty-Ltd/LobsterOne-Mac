import Foundation

/// Today's leaderboard for the screensaver's leaderboard design.
///
/// The leaderboard endpoints take the signed-in session token, not the API key the rest of
/// polling uses, so this reads the stored session and refreshes it when it has expired. Only
/// runs while that design is chosen.
@MainActor
final class ScreensaverLeaderboard {
    /// Lines of code is what the backend ranks in real time; there is no daily token board.
    static let metric = "lines_net"
    static let metricTitle = "lines shipped"
    /// Rows shown: the top of the board, plus yours if you are further down.
    static let topRows = 7

    private let keychain: KeychainService
    private let auth: AuthService
    private let session: URLSession
    private var lastFetch: Date?
    /// The backend caches the board for five minutes; asking more often gains nothing.
    private let minimumInterval: TimeInterval = 4 * 60

    init(keychain: KeychainService = KeychainService(), auth: AuthService = AuthService(), session: URLSession = .shared) {
        self.keychain = keychain
        self.auth = auth
        self.session = session
    }

    /// Nil when signed out, offline, or the board could not be read.
    func fetch(force: Bool = false) async -> ScreensaverSnapshot.Leaderboard? {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < minimumInterval { return nil }
        guard let tokens = try? keychain.getTokens() else { return nil }
        lastFetch = Date()

        do {
            return try await request(idToken: tokens.idToken)
        } catch LeaderboardError.unauthorized {
            // Session tokens last an hour; refresh once and retry.
            do {
                let refreshed = try await auth.refreshTokens(refreshToken: tokens.refreshToken)
                try? keychain.saveTokens(idToken: refreshed.id_token, refreshToken: tokens.refreshToken)
                return try await request(idToken: refreshed.id_token)
            } catch {
                DebugLog.shared.log("Screensaver leaderboard: session refresh failed: \(error.localizedDescription)")
                return nil
            }
        } catch {
            DebugLog.shared.log("Screensaver leaderboard fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func request(idToken: String) async throws -> ScreensaverSnapshot.Leaderboard {
        var request = URLRequest(url: URL(string: "\(Constants.apiURL)/v1/leaderboard/daily?metric=\(Self.metric)")!)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw LeaderboardError.unauthorized }
        guard (200...299).contains(status) else { throw LeaderboardError.http(status) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ScreensaverSnapshot.Leaderboard {
        let decoded = try JSONDecoder().decode(DailyResponse.self, from: data)
        let all = decoded.today.entries
        var shown = Array(all.prefix(topRows))
        if let you = all.first(where: { $0.isYou }), !shown.contains(where: { $0.isYou }) {
            shown.append(you)
        }
        return ScreensaverSnapshot.Leaderboard(
            metric: metricTitle,
            fetchedAt: now,
            yourRank: decoded.today.yourRank,
            yourValue: all.first(where: { $0.isYou })?.value,
            totalUsers: decoded.today.totalUsers,
            entries: shown.map { .init(rank: $0.rank, name: $0.name, value: $0.value, isYou: $0.isYou) })
    }

    enum LeaderboardError: Error {
        case unauthorized
        case http(Int)
    }

    private struct DailyResponse: Decodable {
        let today: Today

        struct Today: Decodable {
            let yourRank: Int?
            let totalUsers: Int
            let entries: [Entry]

            enum CodingKeys: String, CodingKey {
                case yourRank = "your_rank"
                case totalUsers = "total_users"
                case entries
            }
        }

        struct Entry: Decodable {
            let rank: Int
            let name: String
            let value: Double
            let isYou: Bool

            enum CodingKeys: String, CodingKey {
                case rank, name, value
                case isYou = "is_you"
            }
        }
    }
}
