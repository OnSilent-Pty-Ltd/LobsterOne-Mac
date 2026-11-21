import Testing
import Foundation
@testable import LobsterOne

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func paceWarnsWhenProjectedToCapBeforeReset() throws {
    // 192 min into the 5h window at 86% -> ~0.448%/min -> cap in ~31 min, reset in 108 min.
    let w = try #require(SessionPace.warning(percent: 86, resetsAt: now.addingTimeInterval(108 * 60), now: now))
    #expect(w.minutesToCap == 31)
    #expect(w.minutesCappedBeforeReset == 77)
}

@Test func paceSilentWhenUnderPace() {
    // Screenshot case: 7% with 2h51m left.
    #expect(SessionPace.warning(percent: 7, resetsAt: now.addingTimeInterval(171 * 60), now: now) == nil)
}

@Test func paceSilentEarlyInWindow() {
    // 10 min in at 20% would project to 600%, but it's too early to trust.
    #expect(SessionPace.warning(percent: 20, resetsAt: now.addingTimeInterval(290 * 60), now: now) == nil)
}

@Test func paceSilentWhenCappedOrPastReset() {
    #expect(SessionPace.warning(percent: 100, resetsAt: now.addingTimeInterval(60 * 60), now: now) == nil)
    #expect(SessionPace.warning(percent: 50, resetsAt: now.addingTimeInterval(-60), now: now) == nil)
    #expect(SessionPace.warning(percent: 0, resetsAt: now.addingTimeInterval(60 * 60), now: now) == nil)
}

@Test func paceAlertDedupesWithinWindow() {
    let reset = now.addingTimeInterval(60 * 60)
    #expect(!PaceNotifier.sameWindow(nil, reset))
    // Same window, reset time reported a few seconds differently on the next poll.
    #expect(PaceNotifier.sameWindow(reset.timeIntervalSince1970 + 7, reset))
    // Next 5h window.
    #expect(!PaceNotifier.sameWindow(reset.timeIntervalSince1970, reset.addingTimeInterval(5 * 3600)))
}

@Test func weeklyPaceWarnsWhenProjectedToCapBeforeReset() throws {
    // 72h into the week at 70% -> ~0.97%/h -> cap in ~31h, reset in 96h.
    let w = try #require(SessionPace.warning(percent: 70, resetsAt: now.addingTimeInterval(96 * 3600), now: now, limit: .week))
    #expect(w.minutesToCap == 1851)
    #expect(w.minutesCappedBeforeReset == 3909)
    #expect(MenuPopoverView.duration(minutes: w.minutesToCap) == "1d 7h")
    #expect(MenuPopoverView.duration(minutes: w.minutesCappedBeforeReset) == "2d 17h")
}

@Test func weeklyPaceSilentWhenUnderPace() {
    // Screenshot case: 46% with 76h left is 55% through the week, projecting ~84%.
    #expect(SessionPace.warning(percent: 46, resetsAt: now.addingTimeInterval(76 * 3600), now: now, limit: .week) == nil)
}

@Test func weeklyPaceSilentOnFirstDay() {
    // 12h in at 20% projects to 280%, but one heavy day isn't a week.
    #expect(SessionPace.warning(percent: 20, resetsAt: now.addingTimeInterval(156 * 3600), now: now, limit: .week) == nil)
}

@Test func durationRollsIntoDays() {
    #expect(MenuPopoverView.duration(minutes: 1440) == "1d")
    #expect(MenuPopoverView.duration(minutes: 2870) == "2d")
    #expect(MenuPopoverView.duration(minutes: 95) == "1h 35m")
}

@Test func failedAlertRetriesAfterBackoff() {
    #expect(PaceNotifier.shouldRetry(lastFailure: nil, now: now))
    #expect(!PaceNotifier.shouldRetry(lastFailure: now.addingTimeInterval(-60), now: now))
    #expect(PaceNotifier.shouldRetry(lastFailure: now.addingTimeInterval(-PaceNotifier.retryInterval), now: now))
}

@Test func paceSilentWhenLockoutWouldBeUnderFiveMinutes() throws {
    let now = Date()
    // 3h into the session at 60%: the cap lands 2h later, 20 s before the reset.
    let resetsAt = now.addingTimeInterval(2 * 3600 + 20)
    let elapsed = 5 * 3600 - (2 * 3600 + 20.0)
    let percent = 100 * elapsed / (elapsed + 2 * 3600)
    #expect(SessionPace.warning(percent: percent, resetsAt: resetsAt, now: now) == nil)
    // The same pace with a 10-minute lockout still warns, and never says 0m.
    let later = try #require(SessionPace.warning(percent: 100 * 3 / 4.5, resetsAt: now.addingTimeInterval(2 * 3600), now: now))
    #expect(later.minutesCappedBeforeReset >= 5)
}

@Test @MainActor func aPaceWarningFitsOnItsRingAndReadsInFullOnHover() {
    let session = SessionPace.Warning(minutesToCap: 84, minutesCappedBeforeReset: 192)
    #expect(MenuPopoverView.paceLines(session) == ("Cap in 1h 24m", "3h 12m before reset"))
    #expect(MenuPopoverView.paceSentence(session, limit: .session)
        == "At this pace you'll hit the session cap in about 1h 24m, 3h 12m before it resets.")
    let week = SessionPace.Warning(minutesToCap: 32 * 60, minutesCappedBeforeReset: 4 * 24 * 60 + 13 * 60)
    #expect(MenuPopoverView.paceLines(week) == ("Cap in 1d 8h", "4d 13h before reset"))
    #expect(MenuPopoverView.paceSentence(week, limit: .week).hasPrefix("At this pace you'll hit the weekly cap"))
}
