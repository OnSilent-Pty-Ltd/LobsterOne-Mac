import Carbon.HIToolbox
import Foundation

/// Turns what the person presses in Settings into a dictation shortcut. A modifier pressed and
/// let go with nothing else in between is that modifier on its own; any normal key is a
/// combination with whatever modifiers are held at that moment. So ⌃ then Space is ⌃Space,
/// never Control.
///
/// Fed plain keycodes and flags rather than NSEvents so every sequence can be tested.
struct ShortcutRecorder {
    enum Input {
        case modifierDown(keyCode: UInt16)
        case modifierUp(keyCode: UInt16)
        case keyDown(keyCode: UInt16, modifiers: DictationShortcut.Modifiers)
    }

    enum Output: Equatable {
        case recorded(DictationShortcut)
        case cancelled
        /// Not usable; the reason is shown and recording carries on.
        case rejected(String)
    }

    /// Modifiers down right now.
    private var held: Set<ModifierKey> = []
    /// The modifier that could still turn out to be pressed on its own. Cleared as soon as a
    /// second modifier or a normal key joins it.
    private var lone: ModifierKey?

    nonisolated init() {}

    nonisolated mutating func handle(_ input: Input) -> Output? {
        switch input {
        case .modifierDown(let keyCode):
            // Caps Lock and the like aren't dictation keys.
            guard let key = ModifierKey(keyCode: keyCode) else { return nil }
            lone = held.isEmpty ? key : nil
            held.insert(key)
            return nil

        case .modifierUp(let keyCode):
            guard let key = ModifierKey(keyCode: keyCode) else { return nil }
            held.remove(key)
            guard held.isEmpty else { return nil }
            defer { lone = nil }
            guard lone == key else { return nil }
            return .recorded(.modifier(key))

        case .keyDown(let keyCode, let modifiers):
            lone = nil
            if keyCode == UInt16(kVK_Escape) { return .cancelled }
            let shortcut = DictationShortcut.combo(keyCode: keyCode, modifiers: modifiers)
            if let problem = DictationShortcut.problem(with: shortcut) { return .rejected(problem) }
            return .recorded(shortcut)
        }
    }
}
