import Testing
import Foundation
@testable import LobsterOne

/// Feeds a sequence of timed inputs and collects every output, nils included.
private func run(_ steps: [(HoldDetector.Input, TimeInterval)], on detector: inout HoldDetector) -> [HoldDetector.Output?] {
    steps.map { detector.handle($0.0, at: $0.1) }
}

@Test func holdDetectorCleanHoldCommits() {
    var d = HoldDetector()
    #expect(run([(.triggerDown, 10), (.triggerUp, 11.5)], on: &d) == [.begin, .commit])
}

@Test func holdDetectorCommitsRightAtTheMinimum() {
    var d = HoldDetector()
    #expect(run([(.triggerDown, 10), (.triggerUp, 10 + HoldDetector.minimumHold)], on: &d) == [.begin, .commit])
}

@Test func holdDetectorShortTapDiscards() {
    var d = HoldDetector()
    #expect(run([(.triggerDown, 10), (.triggerUp, 10.1)], on: &d) == [.begin, .discard])
}

@Test func holdDetectorChordInsideWindowDiscardsAndStaysInert() {
    for chord: HoldDetector.Input in [.otherKeyDown(isEscape: false), .mouseDown, .otherModifierDown] {
        var d = HoldDetector()
        let outputs = run([
            (.triggerDown, 10),
            (chord, 10.1),
            // Still holding the trigger well past the window: nothing more happens.
            (.otherKeyDown(isEscape: true), 11),
            (.mouseDown, 12),
            (.triggerUp, 13),
        ], on: &d)
        #expect(outputs == [.begin, .discard, nil, nil, nil])
    }
}

@Test func holdDetectorKeysAfterWindowAreIgnored() {
    var d = HoldDetector()
    let outputs = run([
        (.triggerDown, 10),
        (.otherKeyDown(isEscape: false), 10.5),
        (.mouseDown, 10.6),
        (.otherModifierDown, 10.7),
        (.triggerUp, 12),
    ], on: &d)
    #expect(outputs == [.begin, nil, nil, nil, .commit])
}

@Test func holdDetectorEscapeAfterWindowDiscards() {
    var d = HoldDetector()
    let outputs = run([
        (.triggerDown, 10),
        (.otherKeyDown(isEscape: true), 11),
        (.triggerUp, 12),
    ], on: &d)
    #expect(outputs == [.begin, .discard, nil])
}

@Test func holdDetectorEscapeInsideWindowDiscards() {
    var d = HoldDetector()
    #expect(run([(.triggerDown, 10), (.otherKeyDown(isEscape: true), 10.1), (.triggerUp, 11)], on: &d)
        == [.begin, .discard, nil])
}

@Test func holdDetectorNeverBeginsWhenAnotherModifierIsHeld() {
    var d = HoldDetector()
    #expect(d.handle(.triggerDown, at: 10, otherModifiersHeld: true) == nil)
    #expect(d.handle(.triggerDown, at: 10.5) == nil)
    #expect(d.handle(.triggerUp, at: 12) == nil)
    // The next clean press works.
    #expect(run([(.triggerDown, 20), (.triggerUp, 21)], on: &d) == [.begin, .commit])
}

@Test func holdDetectorSecondPressWorksAfterEveryOutcome() {
    let firstPresses: [[(HoldDetector.Input, TimeInterval)]] = [
        [(.triggerDown, 0), (.triggerUp, 1)],                                   // commit
        [(.triggerDown, 0), (.triggerUp, 0.1)],                                 // tap
        [(.triggerDown, 0), (.mouseDown, 0.1), (.triggerUp, 1)],                // chord
        [(.triggerDown, 0), (.otherKeyDown(isEscape: true), 1), (.triggerUp, 2)], // escape
    ]
    for first in firstPresses {
        var d = HoldDetector()
        _ = run(first, on: &d)
        #expect(run([(.triggerDown, 10), (.triggerUp, 11)], on: &d) == [.begin, .commit])
    }
}

@Test func holdDetectorDuplicateEventsAreHarmless() {
    var d = HoldDetector()
    let outputs = run([
        (.triggerUp, 9),       // release with no press
        (.triggerDown, 10),
        (.triggerDown, 10.2),  // repeated down does not restart the clock or begin twice
        (.triggerUp, 10.35),
        (.triggerUp, 10.4),    // repeated up
    ], on: &d)
    #expect(outputs == [nil, .begin, nil, .commit, nil])
}

@Test func holdDetectorIgnoresEverythingWhileIdle() {
    var d = HoldDetector()
    let outputs = run([
        (.otherKeyDown(isEscape: false), 1),
        (.otherKeyDown(isEscape: true), 2),
        (.mouseDown, 3),
        (.otherModifierDown, 4),
    ], on: &d)
    #expect(outputs == [nil, nil, nil, nil])
    #expect(!d.isHolding)
}

@Test func holdDetectorResetDiscardsOnlyARecording() {
    var d = HoldDetector()
    #expect(d.reset() == nil)
    _ = d.handle(.triggerDown, at: 10)
    #expect(d.isHolding)
    #expect(d.reset() == .discard)
    #expect(!d.isHolding)
    #expect(d.handle(.triggerUp, at: 11) == nil)
}

@Test func dictationHotkeyTellsRightOptionFromLeft() {
    let key = ModifierKey.rightOption
    let option = CGEventFlagsRaw.option
    #expect(key.isDown(rawFlags: option | ModifierKey.rightOptionBit))
    // Left Option alone, or Right released while Left is still held.
    #expect(!key.isDown(rawFlags: option | ModifierKey.leftOptionBit))
    #expect(!key.isDown(rawFlags: 0))
    // No device bits at all: trust the generic flag.
    #expect(key.isDown(rawFlags: option))

    #expect(!key.hasOtherModifiers(rawFlags: option | ModifierKey.rightOptionBit))
    #expect(key.hasOtherModifiers(rawFlags: option | ModifierKey.rightOptionBit | ModifierKey.leftOptionBit))
    #expect(key.hasOtherModifiers(rawFlags: option | ModifierKey.rightOptionBit | CGEventFlagsRaw.command))
}

@Test func dictationHotkeyTellsLeftCommandFromRight() {
    let key = ModifierKey.leftCommand
    let command = CGEventFlagsRaw.command
    #expect(key.isDown(rawFlags: command | ModifierKey.leftCommandBit))
    #expect(!key.isDown(rawFlags: command | ModifierKey.rightCommandBit))
    #expect(key.isDown(rawFlags: command))
    #expect(!key.isDown(rawFlags: CGEventFlagsRaw.option | ModifierKey.leftOptionBit))

    #expect(!key.hasOtherModifiers(rawFlags: command | ModifierKey.leftCommandBit))
    #expect(key.hasOtherModifiers(rawFlags: command | ModifierKey.leftCommandBit | ModifierKey.rightCommandBit))
    #expect(key.hasOtherModifiers(rawFlags: command | ModifierKey.leftCommandBit | CGEventFlagsRaw.shift))
    #expect(key.hasOtherModifiers(rawFlags: command | ModifierKey.leftCommandBit | CGEventFlagsRaw.fn))
    // Caps Lock on isn't a chord.
    #expect(!key.hasOtherModifiers(rawFlags: command | ModifierKey.leftCommandBit | CGEventFlagsRaw.capsLock))
}

@Test func dictationHotkeyReadsFnFromItsOnlyFlag() {
    let key = ModifierKey.fn
    #expect(key.isDown(rawFlags: CGEventFlagsRaw.fn))
    #expect(!key.isDown(rawFlags: CGEventFlagsRaw.option | ModifierKey.rightOptionBit))
    #expect(!key.hasOtherModifiers(rawFlags: CGEventFlagsRaw.fn))
    #expect(key.hasOtherModifiers(rawFlags: CGEventFlagsRaw.fn | CGEventFlagsRaw.option))
    #expect(key.hasOtherModifiers(rawFlags: CGEventFlagsRaw.fn | CGEventFlagsRaw.command))
}

@Test func modifierKeysMatchTheirKeycodes() {
    #expect(ModifierKey(keyCode: 61) == .rightOption)
    #expect(ModifierKey(keyCode: 58) == .leftOption)
    #expect(ModifierKey(keyCode: 54) == .rightCommand)
    #expect(ModifierKey(keyCode: 55) == .leftCommand)
    #expect(ModifierKey(keyCode: 62) == .rightControl)
    #expect(ModifierKey(keyCode: 59) == .leftControl)
    #expect(ModifierKey(keyCode: 60) == .rightShift)
    #expect(ModifierKey(keyCode: 56) == .leftShift)
    #expect(ModifierKey(keyCode: 63) == .fn)
    #expect(ModifierKey(keyCode: 57) == nil) // Caps Lock
    #expect(ModifierKey(keyCode: 49) == nil) // Space
}

private enum CGEventFlagsRaw {
    static let capsLock: UInt64 = 0x10000 // kCGEventFlagMaskAlphaShift
    static let shift: UInt64 = 0x20000    // kCGEventFlagMaskShift
    static let option: UInt64 = 0x80000   // kCGEventFlagMaskAlternate
    static let command: UInt64 = 0x100000 // kCGEventFlagMaskCommand
    static let fn: UInt64 = 0x800000      // kCGEventFlagMaskSecondaryFn
}
