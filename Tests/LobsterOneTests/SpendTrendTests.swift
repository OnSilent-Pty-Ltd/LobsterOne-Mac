import Testing
import Foundation
@testable import LobsterOne

private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

@Test func fallingMonthBarEndsAtLastMonth() {
    let t = SpendTrend(thisMonth: 0.64, lastMonth: 2.10, forecast: 1.73)
    #expect(!t.isRising)
    #expect(near(t.change, -0.176))
    #expect(near(t.spentFraction, 0.64 / 2.10))
    #expect(near(t.paceFraction, 1.73 / 2.10))
    #expect(t.lastMonthMark == nil)
}

@Test func risingMonthBarStretchesPastLastMonthAndMarksIt() {
    let t = SpendTrend(thisMonth: 4.24, lastMonth: 6.80, forecast: 11.56)
    #expect(t.isRising)
    #expect(near(t.change, 0.70))
    #expect(near(t.paceFraction, 1))
    #expect(near(t.spentFraction, 4.24 / 11.56))
    #expect(near(t.lastMonthMark, 6.80 / 11.56))
}

@Test func slightlyHigherIsNotRising() {
    let t = SpendTrend(thisMonth: 4, lastMonth: 10, forecast: 11.9)
    #expect(!t.isRising)
    #expect(t.lastMonthMark != nil)
}

@Test func noLastMonthHasNoChangeAndNeverRises() {
    let t = SpendTrend(thisMonth: 2, lastMonth: 0, forecast: 6)
    #expect(!t.isRising)
    #expect(t.change == nil)
    #expect(t.lastMonthMark == nil)
    #expect(near(t.spentFraction, 1.0 / 3))
}

@Test func noForecastYetShowsSpendAgainstLastMonth() {
    let t = SpendTrend(thisMonth: 1, lastMonth: 4, forecast: nil)
    #expect(!t.isRising)
    #expect(t.change == nil)
    #expect(near(t.spentFraction, 0.25))
    #expect(near(t.paceFraction, 0.25))
}

@Test func dailyAverageIsForecastSpreadOverTheMonth() {
    #expect(near(SpendTrend(thisMonth: 11, lastMonth: 0, forecast: 30).dailyAverage(daysInMonth: 30), 1))
    #expect(SpendTrend(thisMonth: 1, lastMonth: 0, forecast: nil).dailyAverage(daysInMonth: 30) == nil)
}

@Test func nothingSpentIsAnEmptyBar() {
    let t = SpendTrend(thisMonth: 0, lastMonth: 0, forecast: 0)
    #expect(t.spentFraction == 0)
    #expect(t.paceFraction == 0)
}

@Test func percentDropsTheSignAndCapsHugeValues() {
    #expect(CostFormat.percent(-0.176) == "18%")
    #expect(CostFormat.percent(0.7) == "70%")
    #expect(CostFormat.percent(25) == "999%+")
}

@Test func directionReadsAsWords() {
    #expect(CostFormat.direction(0.7) == "Up 70%")
    #expect(CostFormat.direction(-0.176) == "Down 18%")
    #expect(CostFormat.direction(0.001) == "No change")
}

@Test func daysInMonth() {
    #expect(CostMath.days(inMonth: "2026-11") == 30)
    #expect(CostMath.days(inMonth: "2028-02") == 29)
    #expect(CostMath.days(inMonth: "nonsense") == nil)
}

@Test func monthNameWithOffsetAcrossTheYearBoundary() {
    let us = Locale(identifier: "en_US")
    #expect(CostFormat.monthName("2026-11", locale: us) == "November")
    #expect(CostFormat.monthName("2026-11", offset: -1, short: true, locale: us) == "Oct")
    #expect(CostFormat.monthName("2026-01", offset: -1, locale: us) == "December")
    #expect(CostFormat.monthName("nonsense", locale: us) == nil)
}
