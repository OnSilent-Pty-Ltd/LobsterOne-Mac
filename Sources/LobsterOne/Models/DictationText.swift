import Foundation

/// Turns what the speech model returned into text fit to paste.
///
/// The model's results arrive in pieces, each with its own spacing, and a pause can leave a
/// line break or a double space between them. A terminal prompt is the main place this text
/// lands, so it is flattened to one line: a stray newline there would submit half a sentence.
nonisolated enum DictationText {
    /// Trims, collapses runs of whitespace and newlines to single spaces. "" when nothing was said.
    static func clean(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
