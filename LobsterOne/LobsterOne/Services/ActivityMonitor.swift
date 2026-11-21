import AppKit
import Combine
import CoreGraphics

@MainActor
final class ActivityMonitor: ObservableObject {
    let idleThreshold: TimeInterval

    @Published private(set) var isSleeping = false

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    nonisolated init(idleThreshold: TimeInterval = 1800) {
        self.idleThreshold = idleThreshold
    }

    func isIdle(secondsSinceLastInput: TimeInterval) -> Bool {
        secondsSinceLastInput >= idleThreshold
    }

    func isIdle() -> Bool {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        return isIdle(secondsSinceLastInput: seconds)
    }

    func start() {
        stop() // Clear any existing observers first
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSleeping = true }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSleeping = false }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }
}
