import Foundation

/// Plays LobsterOne's sound cues in Codex CLI through hooks in ~/.codex/hooks.json.
///
/// Codex only runs a hook after the person trusts it, and trust is tied to the exact text of
/// the declaration: change a command and it quietly stops running. So the declarations here
/// never change. Each one runs a script of ours in Application Support, and those scripts are
/// what get rewritten when the Sounds tab changes. A moment that's off simply has no script.
struct CodexSoundCueInstaller {
    static let marker = SoundCueInstaller.marker

    enum Failure: LocalizedError {
        case unreadableHooks

        var errorDescription: String? {
            "Your Codex hooks file isn't valid JSON, so LobsterOne left it alone. Fix ~/.codex/hooks.json and try again."
        }
    }

    /// One stable hook per Codex event we listen to, each running the script of the same name.
    enum Script: String, CaseIterable {
        case sessionStart = "session-start"
        case permissionRequest = "permission-request"
        case stop
        case userPromptSubmit = "user-prompt-submit"

        var event: String {
            switch self {
            case .sessionStart: "SessionStart"
            case .permissionRequest: "PermissionRequest"
            case .stop: "Stop"
            case .userPromptSubmit: "UserPromptSubmit"
            }
        }

        var matcher: String? { self == .sessionStart ? "^startup$" : nil }

        /// What goes in hooks.json. Prints nothing (a PermissionRequest hook's output could be
        /// read as an answer) and always succeeds.
        var declaration: String {
            "f=\"$HOME/Library/Application Support/LobsterOne/CodexCues/\(rawValue).sh\"; [ -r \"$f\" ] && /bin/sh \"$f\" >/dev/null 2>&1; exit 0 \(CodexSoundCueInstaller.marker)"
        }
    }

    /// What Codex submits when the person approves a plan.
    static let planApprovedPattern = #""prompt" *: *"(Implement the plan\.|Read the approved plan at .* and implement it\.)""#

    let homeDirectory: URL
    let sounds: SoundCueInstaller
    /// How long after a turn ends "waiting" plays, if no new prompt has arrived. Codex has no
    /// idle event, so this stands in for Claude Code's.
    let waitingDelay: Int

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
         sounds: SoundCueInstaller? = nil,
         waitingDelay: Int = 60) {
        self.homeDirectory = homeDirectory
        self.sounds = sounds ?? SoundCueInstaller(homeDirectory: homeDirectory)
        self.waitingDelay = waitingDelay
    }

    var hooksURL: URL { homeDirectory.appendingPathComponent(".codex/hooks.json") }
    private var backupURL: URL { homeDirectory.appendingPathComponent(".codex/hooks.json.lobsterone-backup") }
    /// Must match the path in `Script.declaration`.
    var scriptsDirectory: URL { homeDirectory.appendingPathComponent("Library/Application Support/LobsterOne/CodexCues") }
    private var stampURL: URL { scriptsDirectory.appendingPathComponent("waiting.stamp") }

    func scriptURL(_ script: Script) -> URL { scriptsDirectory.appendingPathComponent("\(script.rawValue).sh") }

    // MARK: Apply

    /// With Codex sounds on, makes sure our hooks are declared (leaving hooks.json untouched when
    /// they already are) and rewrites the scripts. With them off, removes both.
    func apply(_ settings: SoundCueSettings) throws {
        let on = settings.plays(in: .codex)
        try writeScripts(on ? try sounds.commands(for: settings) : [:])
        try updateHooks(install: on)
    }

    /// Each event's script, or nil when it has nothing to do.
    func scripts(for commands: [SoundCue: String]) -> [Script: String] {
        let dir = Self.quoted(scriptsDirectory.path)
        let cancelWaiting = commands[.waiting] == nil ? nil : "rm -f \(dir)/waiting.stamp"
        var bodies: [Script: [String]] = [:]

        bodies[.sessionStart] = [cancelWaiting, commands[.sessionStart]].compactMap { $0 }
        bodies[.permissionRequest] = [commands[.needsPermission]].compactMap { $0 }

        var stop: [String] = []
        if let finished = commands[.finished] { stop.append(finished) }
        if let waiting = commands[.waiting] {
            // A fresh stamp per turn; the timer plays only if nothing has replaced it since.
            stop.append("""
            s="$(date +%s).$$"
            printf '%s\\n' "$s" 2>/dev/null > \(dir)/waiting.stamp || exit 0
            ( sleep \(waitingDelay)
              [ "$(cat \(dir)/waiting.stamp 2>/dev/null)" = "$s" ] || exit 0
              \(waiting)
            ) </dev/null >/dev/null 2>&1 &
            """)
        }
        bodies[.stop] = stop

        var prompt: [String] = []
        if let planApproved = commands[.planApproved] {
            prompt.append("input=$(cat)")
            if let cancelWaiting { prompt.append(cancelWaiting) }
            prompt.append("""
            if printf '%s' "$input" | grep -Eq '\(Self.planApprovedPattern)'; then
            \(planApproved)
            fi
            """)
        } else if let cancelWaiting {
            prompt.append(cancelWaiting)
        }
        bodies[.userPromptSubmit] = prompt

        return bodies.compactMapValues { lines in
            lines.isEmpty ? nil : (["#!/bin/sh", "# Written by LobsterOne for its Codex sound cues; replaced whenever the Sounds tab changes."] + lines)
                .joined(separator: "\n") + "\n"
        }
    }

    private func writeScripts(_ commands: [SoundCue: String]) throws {
        let fm = FileManager.default
        let scripts = scripts(for: commands)
        if !scripts.isEmpty {
            try fm.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for script in Script.allCases {
            let url = scriptURL(script)
            if let text = scripts[script] {
                let data = Data(text.utf8)
                if (try? Data(contentsOf: url)) != data { try Self.atomicWrite(data, to: url) }
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        // Waiting off: a timer still counting down finds no stamp and stays quiet.
        if commands[.waiting] == nil { try? fm.removeItem(at: stampURL) }
    }

    // MARK: hooks.json

    private func updateHooks(install: Bool) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: hooksURL.path)
        let raw = existed ? try Data(contentsOf: hooksURL) : Data()
        // Nothing of ours there and nothing to add: don't even parse the person's file.
        if !install, !String(decoding: raw, as: UTF8.self).contains(Self.marker) { return }

        var json = try Self.parse(raw)
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        if install, Self.hasExactlyOurDeclarations(hooks) { return }

        var updated = SoundCueInstaller.removingOurHooks(from: hooks)
        if install {
            for script in Script.allCases {
                var group: [String: Any] = ["hooks": [["type": "command", "command": script.declaration]]]
                if let matcher = script.matcher { group["matcher"] = matcher }
                updated[script.event] = (updated[script.event] as? [[String: Any]] ?? []) + [group]
            }
        }
        if updated.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = updated }

        // A file we created ourselves goes away again once it has nothing in it.
        if json.isEmpty, existed, !fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: hooksURL)
            return
        }
        if json.isEmpty { json["hooks"] = [String: Any]() }
        try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if existed, !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: hooksURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Self.atomicWrite(data, to: hooksURL)
    }

    /// True when each of our declarations is there once, unchanged, and nothing else of ours is.
    static func hasExactlyOurDeclarations(_ hooks: [String: Any]) -> Bool {
        var ours = 0
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for command in group["hooks"] as? [[String: Any]] ?? [] {
                    if (command["command"] as? String)?.contains(marker) == true { ours += 1 }
                }
            }
        }
        guard ours == Script.allCases.count else { return false }
        return Script.allCases.allSatisfy { script in
            (hooks[script.event] as? [[String: Any]] ?? []).contains { group in
                guard (group["matcher"] as? String) == script.matcher,
                      let commands = group["hooks"] as? [[String: Any]], commands.count == 1 else { return false }
                return commands[0]["type"] as? String == "command" && commands[0]["command"] as? String == script.declaration
            }
        }
    }

    private static func parse(_ data: Data) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["hooks"] == nil || json["hooks"] is [String: Any] else { throw Failure.unreadableHooks }
        return json
    }

    // MARK: Helpers

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes through a temporary file so a reader never sees half a file; owner-only.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Codex keeps its files in ~/.codex; the command may also be on the PATH.
    static func isDetected(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        ConfigService(homeDirectory: homeDirectory).isCodexInstalled()
    }
}
