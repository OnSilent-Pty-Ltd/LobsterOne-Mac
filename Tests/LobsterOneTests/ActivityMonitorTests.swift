import Testing
import Foundation
@testable import LobsterOne

@MainActor @Test func activityMonitorActiveInterval() {
    let monitor = ActivityMonitor(idleThreshold: 1800)
    #expect(monitor.isIdle(secondsSinceLastInput: 0) == false)
    #expect(monitor.isIdle(secondsSinceLastInput: 1799) == false)
    #expect(monitor.isIdle(secondsSinceLastInput: 1800) == true)
    #expect(monitor.isIdle(secondsSinceLastInput: 7200) == true)
}

@MainActor @Test func activityMonitorDefaultsNotSleeping() {
    let monitor = ActivityMonitor()
    #expect(monitor.isSleeping == false)
}
