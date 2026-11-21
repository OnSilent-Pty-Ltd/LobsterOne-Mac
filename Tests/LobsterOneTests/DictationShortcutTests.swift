import Carbon.HIToolbox
import Foundation
import Testing
@testable import LobsterOne

private let space = UInt16(kVK_Space)
private let letterA = UInt16(kVK_ANSI_A)

@Test func dictationShortcutSurvivesARoundTrip() throws {
    let shortcuts: [DictationShortcut] = [
        .modifier(.rightOption), .modifier(.fn), .modifier(.leftShift),
        .combo(keyCode: space, modifiers: [.control, .option]),
        .combo(keyCode: UInt16(kVK_F5), modifiers: []),
    ]
    for shortcut in shortcuts {
        let data = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(DictationShortcut.self, from: data) == shortcut)
        #expect(DictationShortcut.decode(data) == shortcut)
    }
}

@Test func dictationShortcutFallsBackToRightOption() throws {
    #expect(DictationShortcut.decode(nil) == .modifier(.rightOption))
    #expect(DictationShortcut.decode(Data("not json".utf8)) == .modifier(.rightOption))
    #expect(DictationShortcut.decode(Data(#"{"modifier":{"_0":"capsLock"}}"#.utf8)) == .modifier(.rightOption))
    // Readable but not allowed, e.g. written by hand.
    let plain = try JSONEncoder().encode(DictationShortcut.combo(keyCode: letterA, modifiers: []))
    #expect(DictationShortcut.decode(plain) == .modifier(.rightOption))
}

@MainActor @Test func dictationShortcutNames() {
    #expect(DictationShortcut.modifier(.rightOption).displayName == "Right Option (\u{2325})")
    #expect(DictationShortcut.modifier(.leftCommand).displayName == "Left Command (\u{2318})")
    #expect(DictationShortcut.modifier(.fn).displayName == "Fn (Globe)")
    #expect(DictationShortcut.combo(keyCode: space, modifiers: [.control, .option]).displayName == "\u{2303}\u{2325}Space")
    // Always ⌃⌥⇧⌘, whatever order they were added in.
    #expect(DictationShortcut.combo(keyCode: UInt16(kVK_Return), modifiers: [.command, .shift, .control, .option]).displayName
        == "\u{2303}\u{2325}\u{21E7}\u{2318}Return")
    #expect(DictationShortcut.combo(keyCode: UInt16(kVK_F5), modifiers: []).displayName == "F5")
    #expect(DictationShortcut.combo(keyCode: UInt16(kVK_UpArrow), modifiers: [.option]).displayName == "\u{2325}\u{2191}")
    // A letter comes from the keyboard layout, so only its shape is certain here.
    let letter = DictationShortcut.keyName(letterA)
    #expect(letter.count == 1 && letter == letter.uppercased())

    #expect(DictationShortcut.modifier(.rightOption).holdInstruction == "Hold Right Option (\u{2325}), speak, release.")
    #expect(DictationShortcut.combo(keyCode: space, modifiers: [.control, .option]).holdInstruction
        == "Hold \u{2303}\u{2325}Space, speak, release.")
}

@Test func dictationShortcutRules() {
    #expect(DictationShortcut.problem(with: .modifier(.fn)) == nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: space, modifiers: [.control, .option])) == nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: letterA, modifiers: [.command])) == nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: UInt16(kVK_F13), modifiers: [])) == nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: letterA, modifiers: []))
        == "Add a modifier such as \u{2303} or \u{2325}.")
    #expect(DictationShortcut.problem(with: .combo(keyCode: space, modifiers: [])) != nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: letterA, modifiers: [.shift])) != nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: UInt16(kVK_Escape), modifiers: [])) != nil)
    #expect(DictationShortcut.problem(with: .combo(keyCode: UInt16(kVK_Escape), modifiers: [.control])) != nil)
}

@Test func dictationShortcutModifiersFromFlags() {
    // Control + Option, plus Caps Lock and Fn, which a combination ignores.
    let raw: UInt64 = 0x40000 | 0x80000 | 0x10000 | 0x800000
    #expect(DictationShortcut.Modifiers(rawFlags: raw) == [.control, .option])
    #expect(DictationShortcut.Modifiers([.control, .command]).carbonFlags == UInt32(controlKey | cmdKey))
}

// MARK: Recorder

private func record(_ inputs: [ShortcutRecorder.Input]) -> [ShortcutRecorder.Output?] {
    var recorder = ShortcutRecorder()
    return inputs.map { recorder.handle($0) }
}

@Test func shortcutRecorderLoneModifierIsThatModifier() {
    #expect(record([.modifierDown(keyCode: 61), .modifierUp(keyCode: 61)]) == [nil, .recorded(.modifier(.rightOption))])
    #expect(record([.modifierDown(keyCode: 63), .modifierUp(keyCode: 63)]) == [nil, .recorded(.modifier(.fn))])
}

@Test func shortcutRecorderCombination() {
    let outputs = record([
        .modifierDown(keyCode: 59),
        .modifierDown(keyCode: 58),
        .keyDown(keyCode: space, modifiers: [.control, .option]),
    ])
    #expect(outputs == [nil, nil, .recorded(.combo(keyCode: space, modifiers: [.control, .option]))])
}

@Test func shortcutRecorderModifierThenKeyIsACombinationNotTheModifier() {
    let outputs = record([
        .modifierDown(keyCode: 59),
        .keyDown(keyCode: space, modifiers: [.control]),
        .modifierUp(keyCode: 59),
    ])
    #expect(outputs == [nil, .recorded(.combo(keyCode: space, modifiers: [.control])), nil])
}

@Test func shortcutRecorderTwoModifiersTogetherAreNeither() {
    let outputs = record([
        .modifierDown(keyCode: 59),
        .modifierDown(keyCode: 58),
        .modifierUp(keyCode: 58),
        .modifierUp(keyCode: 59),
    ])
    #expect(outputs == [nil, nil, nil, nil])
    // The next clean press still records.
    var recorder = ShortcutRecorder()
    _ = recorder.handle(.modifierDown(keyCode: 59))
    _ = recorder.handle(.modifierDown(keyCode: 58))
    _ = recorder.handle(.modifierUp(keyCode: 58))
    _ = recorder.handle(.modifierUp(keyCode: 59))
    _ = recorder.handle(.modifierDown(keyCode: 55))
    #expect(recorder.handle(.modifierUp(keyCode: 55)) == .recorded(.modifier(.leftCommand)))
}

@Test func shortcutRecorderEscapeCancels() {
    #expect(record([.keyDown(keyCode: UInt16(kVK_Escape), modifiers: [])]) == [.cancelled])
    #expect(record([.modifierDown(keyCode: 59), .keyDown(keyCode: UInt16(kVK_Escape), modifiers: [.control])])
        == [nil, .cancelled])
}

@Test func shortcutRecorderRejectsAPlainKey() {
    #expect(record([.keyDown(keyCode: letterA, modifiers: [])]) == [.rejected("Add a modifier such as \u{2303} or \u{2325}.")])
    // A function key on its own is fine.
    #expect(record([.keyDown(keyCode: UInt16(kVK_F6), modifiers: [])]) == [.recorded(.combo(keyCode: UInt16(kVK_F6), modifiers: []))])
}

@Test func shortcutRecorderIgnoresCapsLock() {
    #expect(record([.modifierDown(keyCode: 57), .modifierUp(keyCode: 57)]) == [nil, nil])
}
