import Foundation

/// The keystrokes that turn what has been typed into a field so far into the newest
/// transcript: Backspaces from the end, then the rest of the new text.
///
/// Counted in `Character`s, because one Backspace removes one grapheme cluster: an accented
/// letter or an emoji goes in one press, however many code points it is made of.
struct TextStreamEdit: Equatable {
    let backspaces: Int
    let insert: String

    nonisolated init(backspaces: Int, insert: String) {
        self.backspaces = backspaces
        self.insert = insert
    }

    /// Keeps the longest shared start and retypes everything after it.
    nonisolated init(from typed: String, to target: String) {
        var common = 0
        for (old, new) in zip(typed, target) {
            guard old == new else { break }
            common += 1
        }
        backspaces = typed.count - common
        insert = String(target.dropFirst(common))
    }

    nonisolated var isEmpty: Bool { backspaces == 0 && insert.isEmpty }
}
