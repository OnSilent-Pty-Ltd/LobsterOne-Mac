import Foundation

/// Decides whether a press of the dictation key is someone dictating or someone typing an
/// Option chord. Recording starts the moment the key goes down, so no words are lost; the
/// first 0.3 s decide whether that recording is kept. Any other key, modifier or click inside
/// that window means a chord (⌥E, ⌥-click), so the recording is thrown away and the rest of
/// the press is ignored. After that only Escape cancels, so the person can keep a hand on the
/// mouse or bump a key without losing what they said.
///
/// Time is passed in rather than read from a clock so the rules can be tested exactly.
struct HoldDetector {
    enum Input { case triggerDown, triggerUp, otherKeyDown(isEscape: Bool), mouseDown, otherModifierDown }
    enum Output: Equatable { case begin, commit, discard }

    nonisolated static let minimumHold: TimeInterval = 0.3

    private enum Phase {
        case idle
        case holding(since: TimeInterval)
        /// The press turned out to be a chord, or was cancelled. Nothing more happens until the
        /// trigger comes back up.
        case ignoringUntilRelease
    }

    private var phase: Phase = .idle

    nonisolated init() {}

    /// A recording is under way and waiting for its outcome.
    nonisolated var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    /// `otherModifiersHeld` is only read for `.triggerDown`: pressing the trigger while
    /// Command, Shift or the like is already down is a chord from the start, so it never begins.
    nonisolated mutating func handle(_ input: Input, at time: TimeInterval, otherModifiersHeld: Bool = false) -> Output? {
        switch phase {
        case .idle:
            guard case .triggerDown = input else { return nil }
            if otherModifiersHeld {
                phase = .ignoringUntilRelease
                return nil
            }
            phase = .holding(since: time)
            return .begin

        case .holding(let since):
            let settled = time - since >= Self.minimumHold
            switch input {
            case .triggerDown:
                // A repeated down event for a key we already know is down.
                return nil
            case .triggerUp:
                phase = .idle
                return settled ? .commit : .discard
            case .otherKeyDown(let isEscape):
                guard !settled || isEscape else { return nil }
                phase = .ignoringUntilRelease
                return .discard
            case .mouseDown, .otherModifierDown:
                guard !settled else { return nil }
                phase = .ignoringUntilRelease
                return .discard
            }

        case .ignoringUntilRelease:
            if case .triggerUp = input { phase = .idle }
            return nil
        }
    }

    /// Drops whatever press is in progress, e.g. after sleep or when dictation is switched off.
    /// Returns `.discard` when a recording was under way, so the caller can throw its audio away.
    nonisolated mutating func reset() -> Output? {
        let wasHolding = isHolding
        phase = .idle
        return wasHolding ? .discard : nil
    }
}
