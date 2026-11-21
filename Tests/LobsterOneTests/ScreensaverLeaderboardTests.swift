import Testing
import Foundation
@testable import LobsterOne

private func board(entries: Int, you: Int?) -> Data {
    let rows = (1...entries).map { #"{"rank":\#($0),"name":"user\#($0)","value":\#(1000 - $0),"user_id":"u\#($0)","is_you":\#($0 == you)}"# }
    let rank = you.map(String.init) ?? "null"
    return Data(#"{"metric":"lines_net","today":{"your_rank":\#(rank),"total_users":\#(entries),"entries":[\#(rows.joined(separator: ","))]},"yesterday":{}}"#.utf8)
}

@MainActor
@Test func leaderboardKeepsTheTopAndAddsYouBelowIt() throws {
    let parsed = try ScreensaverLeaderboard.parse(board(entries: 20, you: 15))
    #expect(parsed.entries.map(\.rank) == [1, 2, 3, 4, 5, 6, 7, 15])
    #expect(parsed.yourRank == 15)
    #expect(parsed.yourValue == 985)
    #expect(parsed.metric == "lines shipped")
}

@MainActor
@Test func leaderboardWithoutYou() throws {
    let parsed = try ScreensaverLeaderboard.parse(board(entries: 3, you: nil))
    #expect(parsed.entries.count == 3)
    #expect(parsed.yourRank == nil)
    #expect(parsed.yourValue == nil)
}
