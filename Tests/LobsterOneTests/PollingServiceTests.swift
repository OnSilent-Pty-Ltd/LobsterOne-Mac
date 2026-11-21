import Testing
import Foundation
@testable import LobsterOne

@MainActor @Test func pollingIntervalActiveIs300Seconds() {
    let polling = PollingService(activityMonitor: ActivityMonitor(idleThreshold: 1800))
    #expect(polling.activeInterval == 300)
    #expect(polling.idleInterval == 900)
}

@MainActor @Test func pollingServiceCalculatesCorrectInterval() {
    let polling = PollingService(activityMonitor: ActivityMonitor(idleThreshold: 1800))
    #expect(polling.currentInterval(secondsSinceLastInput: 0) == 300)
    #expect(polling.currentInterval(secondsSinceLastInput: 1799) == 300)
    #expect(polling.currentInterval(secondsSinceLastInput: 1800) == 900)
    #expect(polling.currentInterval(secondsSinceLastInput: 7200) == 900)
}

@MainActor @Test func pollingIntervalCollapsesToBlockedCadenceWhenPolicyIsBlock() {
    let activity = ActivityMonitor(idleThreshold: 1800)
    let policy = ClientPolicyService(defaults: UserDefaults(suiteName: "polling-test-\(UUID().uuidString)")!)
    let svc = PollingService(activityMonitor: activity, clientPolicy: policy)

    // Active user, normal policy → activeInterval (300 s).
    #expect(svc.currentInterval(secondsSinceLastInput: 0) == Constants.pollingActiveInterval)

    // Active user, blocked → fast-poll (60 s).
    policy.update(ClientPolicy(level: .block, message: "x", downloadUrl: "y"))
    #expect(svc.currentInterval(secondsSinceLastInput: 0) == Constants.pollingBlockedInterval)

    // Idle user, blocked → still fast-poll (block dominates idle).
    #expect(svc.currentInterval(secondsSinceLastInput: 9999) == Constants.pollingBlockedInterval)

    // Recovery → normal cadence resumes.
    policy.update(ClientPolicy(level: .ok))
    #expect(svc.currentInterval(secondsSinceLastInput: 0) == Constants.pollingActiveInterval)
}

@MainActor
@Test func pollingIntervalIsOneMinuteWhileScreensaverShows() {
    let service = PollingService()
    service.isScreensaverShowing = { true }
    #expect(service.currentInterval(secondsSinceLastInput: 0) == 60)
    #expect(service.currentInterval(secondsSinceLastInput: 3600) == 60)

    service.isScreensaverShowing = { false }
    #expect(service.currentInterval(secondsSinceLastInput: 3600) == 900)
}
