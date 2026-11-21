import Testing
import Foundation
@testable import LobsterOne

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Test func tokenRateIsZeroUntilSecondPoll() {
    var rate = TokenRate()
    #expect(rate.record(tokens: 500_000, at: start) == 0)
}

@Test func tokenRateIsGrowthPerMinute() {
    var rate = TokenRate()
    _ = rate.record(tokens: 500_000, at: start)
    #expect(rate.record(tokens: 512_000, at: start.addingTimeInterval(60)) == 12_000)
    // Five minutes with 30K more is 6K a minute.
    #expect(rate.record(tokens: 542_000, at: start.addingTimeInterval(360)) == 6_000)
    #expect(rate.record(tokens: 542_000, at: start.addingTimeInterval(420)) == 0)
}

@Test func tokenRateIgnoresPollsTooCloseTogether() {
    var rate = TokenRate()
    _ = rate.record(tokens: 500_000, at: start)
    _ = rate.record(tokens: 512_000, at: start.addingTimeInterval(60))
    // A manual refresh 5 seconds later keeps the rate and the baseline.
    #expect(rate.record(tokens: 512_000, at: start.addingTimeInterval(65)) == 12_000)
    #expect(rate.record(tokens: 518_000, at: start.addingTimeInterval(120)) == 6_000)
}

@Test func tokenRateResetsOnDayRolloverAndLongGaps() {
    var rate = TokenRate()
    _ = rate.record(tokens: 500_000, at: start)
    _ = rate.record(tokens: 512_000, at: start.addingTimeInterval(60))
    #expect(rate.record(tokens: 3_000, at: start.addingTimeInterval(120)) == 0)
    #expect(rate.record(tokens: 9_000, at: start.addingTimeInterval(180)) == 6_000)
    // Back from two hours asleep: no rate, then normal again.
    #expect(rate.record(tokens: 90_000, at: start.addingTimeInterval(180 + 7200)) == 0)
    #expect(rate.record(tokens: 93_000, at: start.addingTimeInterval(240 + 7200)) == 3_000)
}
