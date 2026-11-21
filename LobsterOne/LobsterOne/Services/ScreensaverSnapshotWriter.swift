import Foundation

/// Keeps `screensaver.json` in step with what the menu bar shows.
@MainActor
final class ScreensaverSnapshotWriter {
    private let fileURL: URL
    private var lastWritten: ScreensaverSnapshot?
    /// The app starts with an empty, offline placeholder state. Writing that would replace a
    /// good snapshot with zeros on every launch, so nothing is written until real data arrives.
    private var hasSeenData = false
    private var lastQuota: QuotaState?
    private var lastBurn: SevenDayBurn?

    /// Extras beyond the polled figures. Setting one rewrites the file if there is data.
    var style: ScreensaverStyle = .standard { didSet { rewrite() } }
    var sources: [ScreensaverSnapshot.Source] = [] { didSet { rewrite() } }
    var leaderboard: ScreensaverSnapshot.Leaderboard? { didSet { rewrite() } }

    init(fileURL: URL = ScreensaverSnapshot.fileURL(home: ScreensaverSnapshot.realHome)) {
        self.fileURL = fileURL
    }

    func update(quota: QuotaState, burn: SevenDayBurn?) {
        if !quota.isOffline { hasSeenData = true }
        lastQuota = quota
        lastBurn = burn
        rewrite()
    }

    private func rewrite() {
        guard hasSeenData, let quota = lastQuota else { return }
        var snapshot = ScreensaverSnapshot.from(quota: quota, burn: lastBurn)
        snapshot.style = style
        snapshot.sources = sources.isEmpty ? nil : sources
        snapshot.leaderboard = style == .leaderboard ? leaderboard : nil
        guard snapshot != lastWritten else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: fileURL, options: .atomic)
            // Usage numbers only, but still nobody else's business on a shared Mac.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastWritten = snapshot
        } catch {
            DebugLog.shared.log("Screensaver snapshot write failed: \(error.localizedDescription)")
        }
    }

    /// On sign-out, so the screensaver stops showing the previous account's numbers.
    func remove() {
        lastWritten = nil
        hasSeenData = false
        lastQuota = nil
        lastBurn = nil
        leaderboard = nil
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was written yet.
        } catch {
            DebugLog.shared.log("Screensaver snapshot removal failed: \(error.localizedDescription)")
        }
    }
}

extension ScreensaverSnapshot {
    static func from(quota: QuotaState, burn: SevenDayBurn?) -> ScreensaverSnapshot {
        ScreensaverSnapshot(
            updatedAt: quota.lastUpdated,
            tokens: quota.usedTokens,
            percentUsed: quota.percentUsed,
            isRealQuota: quota.isRealQuota,
            plan: quota.displayPlanTier,
            isOffline: quota.isOffline,
            tokensPerMinute: quota.tokensPerMinute,
            resetsAt: quota.anthropicState?.fiveHourResetsAt,
            sevenDay: (burn?.days ?? []).map { Day(date: $0.date, tokens: $0.tokens) }
        )
    }
}
