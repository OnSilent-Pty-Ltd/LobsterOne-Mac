import Foundation

/// Plays LobsterOne's sound cues in Mistral Vibe (3.1.1 or newer) through hooks in
/// ~/.vibe/hooks.toml. LobsterOne owns one fenced block of `[[hooks]]` tables at the end of the
/// file and never parses or rewrites anything outside it.
///
/// Vibe kills anything a hook leaves running in the background, so these commands wait for the
/// sound to finish instead of detaching it.
struct VibeSoundCueInstaller {
    static let beginMarker = "# >>> lobsterone-sound-cue (managed by LobsterOne; edits inside this block are replaced)"
    static let endMarker = "# <<< lobsterone-sound-cue"
    private static let beginPrefix = "# >>> lobsterone-sound-cue"
    private static let namePrefix = "lobsterone-"

    enum Failure: LocalizedError, Equatable {
        case unreadableHooks
        case brokenBlock
        case nameOutsideBlock

        var errorDescription: String? {
            switch self {
            case .unreadableHooks:
                "LobsterOne couldn't read ~/.vibe/hooks.toml as text, so it left the file alone."
            case .brokenBlock:
                "The LobsterOne section in ~/.vibe/hooks.toml has lost a start or end line, or appears twice, so LobsterOne left the file alone. Delete the lines from \u{201C}# >>> lobsterone-sound-cue\u{201D} to \u{201C}# <<< lobsterone-sound-cue\u{201D} and try again."
            case .nameOutsideBlock:
                "~/.vibe/hooks.toml has a hook named \u{201C}lobsterone-\u{2026}\u{201D} outside LobsterOne's section, so LobsterOne left the file alone. Rename or remove it and try again."
            }
        }
    }

    /// The Vibe hook for each moment it can play. Plan approved has none: Vibe has no plan mode.
    static func hook(for cue: SoundCue) -> (name: String, type: String, match: String)? {
        switch cue {
        case .sessionStart: ("lobsterone-session-start", "session_start", "startup")
        case .needsPermission: ("lobsterone-needs-permission", "notification", "approval_requested")
        case .waiting: ("lobsterone-waiting", "notification", "question_asked")
        case .finished: ("lobsterone-finished", "notification", "turn_completed")
        case .planApproved: nil
        }
    }

    let homeDirectory: URL
    let sounds: SoundCueInstaller

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()), sounds: SoundCueInstaller? = nil) {
        self.homeDirectory = homeDirectory
        self.sounds = sounds ?? SoundCueInstaller(homeDirectory: homeDirectory)
    }

    var hooksURL: URL { homeDirectory.appendingPathComponent(".vibe/hooks.toml") }
    private var backupURL: URL { homeDirectory.appendingPathComponent(".vibe/hooks.toml.lobsterone-backup") }

    // MARK: Apply

    /// Replaces our block with one for the moments that are on, or removes it when Vibe sounds
    /// are off. Leaves the file untouched when nothing changes.
    func apply(_ settings: SoundCueSettings) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: hooksURL.path)
        var original: String?
        if existed {
            guard let text = String(data: try Data(contentsOf: hooksURL), encoding: .utf8) else { throw Failure.unreadableHooks }
            original = text
        }
        let on = settings.plays(in: .vibe)
        // Nothing of ours there and nothing to add: leave the person's file alone, however it looks.
        if !on, original?.contains("lobsterone-") != true { return }

        var text = try Self.removingBlock(from: original ?? "")
        if on {
            let commands = try sounds.commands(for: settings, background: false)
            if let block = Self.block(commands) {
                if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
                text += block
            }
        }
        if text == original || (!existed && text.isEmpty) { return }

        // A file we created ourselves goes away again once it has nothing in it.
        if existed, text.allSatisfy(\.isWhitespace), !fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: hooksURL)
            return
        }
        try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if existed, !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: hooksURL, to: backupURL)
        }
        try CodexSoundCueInstaller.atomicWrite(Data(text.utf8), to: hooksURL)
    }

    /// Our block for these commands, or nil when no moment Vibe supports is on.
    static func block(_ commands: [SoundCue: String]) -> String? {
        let tables = SoundCue.allCases.compactMap { cue -> String? in
            guard let command = commands[cue], let hook = hook(for: cue) else { return nil }
            return """
            [[hooks]]
            name = "\(hook.name)"
            type = "\(hook.type)"
            match = "\(hook.match)"
            command = \(tomlString(command))
            timeout = 10.0
            """
        }
        guard !tables.isEmpty else { return nil }
        return ([beginMarker] + [tables.joined(separator: "\n\n")] + [endMarker]).joined(separator: "\n") + "\n"
    }

    /// The text without our block, and without the blank line we put ahead of it. Refuses a
    /// block that's been split or copied, or a hook of ours that has wandered out of it.
    static func removingBlock(from text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let begins = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(beginPrefix) }
        let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == endMarker }
        guard begins.count == ends.count, begins.count <= 1 else { throw Failure.brokenBlock }
        if let begin = begins.first, let end = ends.first {
            guard begin < end else { throw Failure.brokenBlock }
            var start = begin
            if start > 0, lines[start - 1].isEmpty { start -= 1 }
            lines.removeSubrange(start...end)
        }
        let rest = lines.joined(separator: "\n")
        if rest.range(of: #"(?m)^\s*name\s*=\s*["']\#(namePrefix)"#, options: .regularExpression) != nil {
            throw Failure.nameOutsideBlock
        }
        return rest
    }

    /// A TOML basic string: quotes, backslashes and control characters escaped.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Vibe keeps its sessions and settings in ~/.vibe; the command may also be on the PATH.
    static func isDetected(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(".vibe").path)
            || ConfigService(homeDirectory: homeDirectory).isVibeInstalled()
    }
}
