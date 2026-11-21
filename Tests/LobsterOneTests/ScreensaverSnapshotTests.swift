import Testing
import Foundation
@testable import LobsterOne

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("lobsterone-snapshot-\(UUID().uuidString)")
        .appendingPathComponent("screensaver.json")
}

private func onlineQuota(tokens: Int = 7_600_000, updated: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> QuotaState {
    var quota = QuotaState.empty
    quota.usedTokens = tokens
    quota.percentUsed = 33
    quota.planTier = "max20"
    quota.isOffline = false
    quota.tokensPerMinute = 84_000
    quota.lastUpdated = updated
    return quota
}

@Test func snapshotMapsQuotaAndBurn() {
    var quota = onlineQuota()
    var anthropic = AnthropicQuotaState()
    anthropic.fiveHourResetsAt = Date(timeIntervalSince1970: 1_800_003_600)
    quota.anthropicState = anthropic
    quota.isRealQuota = true
    let burn = SevenDayBurn.from([
        DailyUsage(date: "2026-11-14", inputTokens: 200, outputTokens: 100, costUsd: 1.0),
        DailyUsage(date: "2026-11-15", inputTokens: 100, outputTokens: 50, costUsd: 0.5),
    ])

    let snapshot = ScreensaverSnapshot.from(quota: quota, burn: burn)

    #expect(snapshot.version == ScreensaverSnapshot.currentVersion)
    #expect(snapshot.tokens == 7_600_000)
    #expect(snapshot.percentUsed == 33)
    #expect(snapshot.isRealQuota)
    #expect(snapshot.plan == "Max 20x")
    #expect(snapshot.tokensPerMinute == 84_000)
    #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    #expect(snapshot.sevenDay == [.init(date: "2026-11-14", tokens: 300), .init(date: "2026-11-15", tokens: 150)])
}

@Test func snapshotRoundTripsWithSnakeCaseKeysAndNoCost() throws {
    let burn = SevenDayBurn.from([DailyUsage(date: "2026-11-15", inputTokens: 100, outputTokens: 50, costUsd: 0.5)])
    let snapshot = ScreensaverSnapshot.from(quota: onlineQuota(), burn: burn)

    let data = try snapshot.encoded()
    let text = String(decoding: data, as: UTF8.self)

    #expect(text.contains("\"percent_used\""))
    #expect(text.contains("\"seven_day\""))
    #expect(text.contains("\"tokens_per_minute\""))
    #expect(!text.contains("cost"))
    #expect(ScreensaverSnapshot.decode(data) == snapshot)
}

@Test func snapshotDecodeRejectsNewerVersionAndGarbage() throws {
    var snapshot = ScreensaverSnapshot.from(quota: onlineQuota(), burn: nil)
    snapshot.version = ScreensaverSnapshot.currentVersion + 1

    #expect(ScreensaverSnapshot.decode(try snapshot.encoded()) == nil)
    #expect(ScreensaverSnapshot.decode(Data("not json".utf8)) == nil)
}

@MainActor
@Test func writerSkipsLaunchPlaceholderThenWrites() throws {
    let url = tempFile()
    let writer = ScreensaverSnapshotWriter(fileURL: url)

    writer.update(quota: .empty, burn: nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    writer.update(quota: onlineQuota(), burn: nil)
    let written = try #require(ScreensaverSnapshot.decode(try Data(contentsOf: url)))
    #expect(written.tokens == 7_600_000)

    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@MainActor
@Test func writerRecordsGoingOfflineAfterData() throws {
    let url = tempFile()
    let writer = ScreensaverSnapshotWriter(fileURL: url)
    writer.update(quota: onlineQuota(), burn: nil)

    var offline = onlineQuota()
    offline.isOffline = true
    writer.update(quota: offline, burn: nil)

    let written = try #require(ScreensaverSnapshot.decode(try Data(contentsOf: url)))
    #expect(written.isOffline)
    #expect(written.tokens == 7_600_000)
}

@MainActor
@Test func writerRemoveDeletesFileAndRearmsPlaceholderGuard() throws {
    let url = tempFile()
    let writer = ScreensaverSnapshotWriter(fileURL: url)
    writer.update(quota: onlineQuota(), burn: nil)

    writer.remove()
    #expect(!FileManager.default.fileExists(atPath: url.path))

    writer.remove()  // Second call with nothing there must not throw or log a failure.
    writer.update(quota: .empty, burn: nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func snapshotReadsFilesWithoutTheNewFields() throws {
    // Written by the first screensaver release: no style, sources or leaderboard.
    let old = #"{"version":1,"updated_at":"2026-11-15T02:49:21Z","tokens":548597,"percent_used":79,"is_real_quota":true,"plan":"Max 5X","is_offline":false,"tokens_per_minute":0,"seven_day":[]}"#
    let snapshot = try #require(ScreensaverSnapshot.decode(Data(old.utf8)))
    #expect(snapshot.style == nil)
    #expect(snapshot.sources == nil)
    #expect(snapshot.leaderboard == nil)
}

@MainActor
@Test func writerCarriesStyleAndOnlyKeepsTheBoardForTheLeaderboard() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lobsterone-snapshot-\(UUID().uuidString)/screensaver.json")
    let writer = ScreensaverSnapshotWriter(fileURL: url)
    var quota = QuotaState.empty
    quota.isOffline = false
    quota.usedTokens = 1000
    writer.update(quota: quota, burn: nil)
    writer.leaderboard = .init(metric: "lines shipped", fetchedAt: Date(), yourRank: 3, yourValue: 10, totalUsers: 9,
                               entries: [.init(rank: 3, name: "you", value: 10, isYou: true)])
    var written = try #require(ScreensaverSnapshot.decode(try Data(contentsOf: url)))
    #expect(written.style == .standard)
    #expect(written.leaderboard == nil)

    writer.style = .leaderboard
    written = try #require(ScreensaverSnapshot.decode(try Data(contentsOf: url)))
    #expect(written.style == .leaderboard)
    #expect(written.leaderboard?.yourRank == 3)
}
