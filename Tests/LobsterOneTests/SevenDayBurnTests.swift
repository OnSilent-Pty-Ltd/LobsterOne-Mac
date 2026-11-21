import Testing
import Foundation
@testable import LobsterOne

@Test func sevenDayBurnMapsBucketsInOrder() {
    // Server sends 7 zero-filled buckets, oldest -> newest. We render them as-is.
    let buckets = [
        DailyUsage(date: "2026-05-23", inputTokens: 0, outputTokens: 0, costUsd: 0),
        DailyUsage(date: "2026-05-24", inputTokens: 0, outputTokens: 0, costUsd: 0),
        DailyUsage(date: "2026-05-25", inputTokens: 0, outputTokens: 0, costUsd: 0),
        DailyUsage(date: "2026-05-26", inputTokens: 0, outputTokens: 0, costUsd: 0),
        DailyUsage(date: "2026-05-27", inputTokens: 200, outputTokens: 100, costUsd: 1.0),
        DailyUsage(date: "2026-05-28", inputTokens: 0, outputTokens: 0, costUsd: 0),
        DailyUsage(date: "2026-05-29", inputTokens: 100, outputTokens: 50, costUsd: 0.5),
    ]
    let burn = SevenDayBurn.from(buckets)
    #expect(burn.bars == [0, 0, 0, 0, 300, 0, 150])
    #expect(burn.totalTokens == 450)
    #expect(burn.costUsd == 1.5)
}

@Test func sevenDayBurnEmptyIsAllZeros() {
    let burn = SevenDayBurn.from([])
    #expect(burn.bars == [])
    #expect(burn.totalTokens == 0)
    #expect(burn.costUsd == 0)
}

@Test func sevenDayBurnClampsNegativeTokens() {
    // Defensive: never let a bogus negative token count subtract from the bar.
    let burn = SevenDayBurn.from([
        DailyUsage(date: "2026-05-29", inputTokens: -5, outputTokens: 50, costUsd: 0.25),
    ])
    #expect(burn.bars == [50])
    #expect(burn.totalTokens == 50)
    #expect(burn.costUsd == 0.25)
}

@Test func dailyUsageDecodesSnakeCaseAndDefaultsMissing() throws {
    let json = """
    [{"date":"2026-05-29","input_tokens":100,"output_tokens":50,"cost_usd":0.5},
     {"date":"2026-05-28"}]
    """.data(using: .utf8)!
    let days = try JSONDecoder().decode([DailyUsage].self, from: json)
    #expect(days.count == 2)
    #expect(days[0].inputTokens == 100)
    #expect(days[0].costUsd == 0.5)
    #expect(days[1].inputTokens == 0)   // missing numeric fields default to 0
    #expect(days[1].costUsd == 0)
}

@Test func formatTokensAbbreviates() {
    #expect(SevenDayBurn.formatTokens(450) == "450")
    #expect(SevenDayBurn.formatTokens(12_400) == "12K")
    #expect(SevenDayBurn.formatTokens(1_240_000) == "1.2M")
    #expect(SevenDayBurn.formatTokens(2_000_000) == "2M")
}

@Test func formatTokensTierBoundaries() {
    #expect(SevenDayBurn.formatTokens(1_000) == "1K")
    #expect(SevenDayBurn.formatTokens(1_000_000) == "1M")
}

@Test func sevenDayBurnKeepsServerDatesAndCostPerDay() {
    let burn = SevenDayBurn.from([
        DailyUsage(date: "2026-11-11", inputTokens: 200, outputTokens: 100, costUsd: 1.25),
        DailyUsage(date: "2026-11-12", inputTokens: 10, outputTokens: 5, costUsd: 0.1),
    ])
    #expect(burn.days.map(\.date) == ["2026-11-11", "2026-11-12"])
    #expect(burn.days.map(\.tokens) == burn.bars)
    #expect(burn.days[0].costUsd == 1.25)
    // Labels name the server's bucket regardless of the machine's timezone.
    #expect(burn.days[0].weekdayInitial == "W")
    #expect(burn.days[0].longLabel == "Wed 11 Nov")
}

@Test func sevenDayBurnDayIsTodayUsesLocalCalendarDate() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
    // 2026-11-12 22:31 UTC is already 13 Nov in Sydney.
    let now = Date(timeIntervalSince1970: 1_794_522_660)
    #expect(SevenDayBurn.Day(date: "2026-11-13", tokens: 0, costUsd: 0).isToday(now: now, calendar: cal))
    #expect(!SevenDayBurn.Day(date: "2026-11-12", tokens: 0, costUsd: 0).isToday(now: now, calendar: cal))
}
