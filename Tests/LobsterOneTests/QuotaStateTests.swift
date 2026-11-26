import Testing
import Foundation
@testable import LobsterOne

@Test func quotaStateFormatsTokensCompact() {
    let state = QuotaState(
        usedTokens: 1_200_000,
        usedRequests: 188,
        limitRequests: 250,
        planTier: "pro",
        percentUsed: 75.2,
        lastUpdated: Date(),
        isOffline: false,
        offlineReason: "",
        hasQuota: true
    )
    #expect(state.formattedTokens == "1.200M")
    #expect(state.formattedPercent == "~75%")
    #expect(state.menuBarText == "1.200M")
}

@Test func quotaStateFormatsTokensThousands() {
    let state = QuotaState(
        usedTokens: 450_000,
        usedRequests: 50,
        limitRequests: 250,
        planTier: "pro",
        percentUsed: 20.0,
        lastUpdated: Date(),
        isOffline: false,
        offlineReason: "",
        hasQuota: true
    )
    #expect(state.formattedTokens == "450K")
    #expect(state.menuBarText == "450K")
}

@Test func quotaStateOfflineText() {
    let state = QuotaState(
        usedTokens: 1_200_000,
        usedRequests: 188,
        limitRequests: 250,
        planTier: "pro",
        percentUsed: 75.2,
        lastUpdated: Date(),
        isOffline: true,
        offlineReason: "401 Unauthorized on /quota",
        hasQuota: true
    )
    #expect(state.menuBarText == "1.200M / offline")
}

@Test func quotaStateColorThresholds() {
    let low = QuotaState(usedTokens: 0, usedRequests: 0, limitRequests: 250, planTier: "pro", percentUsed: 20.0, lastUpdated: Date(), isOffline: false, offlineReason: "", hasQuota: true)
    #expect(low.statusLevel == .ok)

    let mid = QuotaState(usedTokens: 0, usedRequests: 0, limitRequests: 250, planTier: "pro", percentUsed: 65.0, lastUpdated: Date(), isOffline: false, offlineReason: "", hasQuota: true)
    #expect(mid.statusLevel == .warning)

    let high = QuotaState(usedTokens: 0, usedRequests: 0, limitRequests: 250, planTier: "pro", percentUsed: 85.0, lastUpdated: Date(), isOffline: false, offlineReason: "", hasQuota: true)
    #expect(high.statusLevel == .critical)

    let offline = QuotaState(usedTokens: 0, usedRequests: 0, limitRequests: 250, planTier: "pro", percentUsed: 85.0, lastUpdated: Date(), isOffline: true, offlineReason: "", hasQuota: true)
    #expect(offline.statusLevel == .offline)
}

@Test func quotaStateFormatsTokensBoundary() {
    let state = QuotaState(
        usedTokens: 999_999,
        usedRequests: 0,
        limitRequests: 250,
        planTier: "pro",
        percentUsed: 0,
        lastUpdated: Date(),
        isOffline: false,
        offlineReason: "",
        hasQuota: true
    )
    #expect(state.formattedTokens == "1M")
}

@Test func quotaStateNoQuotaShowsTokensOnly() {
    let state = QuotaState(
        usedTokens: 7_600_000,
        usedRequests: 0,
        limitRequests: 0,
        planTier: "",
        percentUsed: 0,
        lastUpdated: Date(),
        isOffline: false,
        offlineReason: "401 Unauthorized on /quota",
        hasQuota: false
    )
    #expect(state.menuBarText == "7.600M")
}

@Test func mergingAnthropicQuotaDropsTheTilde() {
    let estimate = QuotaState(
        usedTokens: 61_000, usedRequests: 0, limitRequests: 0,
        planTier: "", percentUsed: 0.4, lastUpdated: Date(),
        isOffline: false, offlineReason: "", hasQuota: true
    )
    #expect(estimate.formattedPercent == "~0%")

    var anth = AnthropicQuotaState()
    anth.fiveHourPct = 12
    anth.subscriptionType = "max"

    // Not fetched yet, or fell back: the estimate stands.
    anth.source = .robocogP90
    #expect(estimate.merging(anthropic: anth).isRealQuota == false)
    #expect(estimate.merging(anthropic: anth).formattedPercent == "~0%")

    anth.source = .oauthAPI
    let merged = estimate.merging(anthropic: anth)
    #expect(merged.isRealQuota)
    #expect(merged.formattedPercent == "12%")
    #expect(merged.usedTokens == 61_000)
    #expect(merged.anthropicState?.fiveHourPct == 12)
}
