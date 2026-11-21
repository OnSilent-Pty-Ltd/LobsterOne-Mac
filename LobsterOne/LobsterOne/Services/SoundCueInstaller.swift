import AppKit
import Foundation

/// Writes LobsterOne's sound cues into Claude Code as `afplay` hooks in ~/.claude/settings.json,
/// so they play even when the app isn't running. Only touches hooks it wrote itself (marked by
/// `marker`); the person's own hooks are left exactly as they were.
struct SoundCueInstaller {
    /// Appended to every command we write, so we can find our hooks again and only ours.
    static let marker = "# lobsterone-sound-cue"

    enum Failure: LocalizedError {
        case unreadableSettings

        var errorDescription: String? {
            "Your Claude Code settings file isn't valid JSON, so LobsterOne left it alone. Fix ~/.claude/settings.json and try again."
        }
    }

    let homeDirectory: URL
    let soundsDirectory: URL

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
         soundsDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.soundsDirectory = soundsDirectory ?? homeDirectory
            .appendingPathComponent("Library/Application Support/LobsterOne/Sounds")
    }

    private var settingsURL: URL { homeDirectory.appendingPathComponent(".claude/settings.json") }
    private var backupURL: URL { homeDirectory.appendingPathComponent(".claude/settings.json.lobsterone-backup") }

    // MARK: Apply

    /// Makes the hooks match `settings`: removes every hook we wrote before, then adds one per
    /// cue that's on (none when sounds are off).
    func apply(_ settings: SoundCueSettings) throws {
        var json = try readSettings()
        var hooks = Self.removingOurHooks(from: json["hooks"] as? [String: Any] ?? [:])

        if settings.plays(in: .claude) {
            for cue in SoundCue.allCases {
                let entry = settings.entry(cue)
                guard entry.on else { continue }
                let paths = try sounds(for: entry).compactMap { try soundPath(for: $0) }
                guard !paths.isEmpty else { continue }
                var group: [String: Any] = ["hooks": [["type": "command", "command": Self.command(paths: paths, volume: settings.volume(for: cue), quiet: settings.quietTimes)]]]
                if let matcher = cue.hookMatcher { group["matcher"] = matcher }
                var groups = hooks[cue.hookEvent] as? [[String: Any]] ?? []
                groups.append(group)
                hooks[cue.hookEvent] = groups
            }
        }

        if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        try writeSettings(json)
    }

    /// What a cue plays: every numbered version of its sound when it's set to random, else
    /// the one sound.
    func sounds(for entry: SoundCueSettings.Entry) -> [SoundChoice] {
        entry.random ? SoundChoice.variants(of: entry.sound, custom: customSounds()) : [entry.sound]
    }

    static func command(path: String, volume: Double) -> String {
        command(paths: [path], volume: volume)
    }

    /// With several paths, the shell picks one at random each time the hook runs. With quiet
    /// times, it checks the clock first: the hooks run without the app, so the check lives here.
    /// `background: false` waits for the sound to end and exits 0, for tools (Mistral Vibe) that
    /// kill whatever a hook leaves running.
    static func command(paths: [String], volume: Double, quiet: [QuietTime] = [], background: Bool = true) -> String {
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let v = String(format: "%.2f", min(1, max(0.05, volume)))
        let detach = background ? " >/dev/null 2>&1 &" : " >/dev/null 2>&1;"
        let play = quoted.count > 1
            ? "set -- \(quoted.joined(separator: " ")); shift $((RANDOM % \(quoted.count))); afplay -v \(v) \"$1\"\(detach)"
            : "afplay -v \(v) \(quoted[0])\(detach)"
        let end = background ? "" : " exit 0;"
        guard !quiet.isEmpty else { return "\(play)\(end) \(marker)" }
        let tests = quiet.map(\.shellTest).joined(separator: " || ")
        return "t=$(date +%H%M); if ! { \(tests); }; then \(play) fi\(background ? "" : ";")\(end) \(marker)"
    }

    /// What each moment plays for `settings`, as hook commands; moments that are off, or whose
    /// sound is missing, are left out. Shared by the Codex and Vibe installers.
    func commands(for settings: SoundCueSettings, background: Bool = true) throws -> [SoundCue: String] {
        var result: [SoundCue: String] = [:]
        for cue in SoundCue.allCases {
            let entry = settings.entry(cue)
            guard entry.on else { continue }
            let paths = try sounds(for: entry).compactMap { try soundPath(for: $0) }
            guard !paths.isEmpty else { continue }
            result[cue] = Self.command(paths: paths, volume: settings.volume(for: cue), quiet: settings.quietTimes, background: background)
        }
        return result
    }

    /// Drops our hook commands, then any group or event left empty by that.
    static func removingOurHooks(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let commands = group["hooks"] as? [[String: Any]] else { return group }
                let mine = commands.filter { ($0["command"] as? String)?.contains(marker) == true }
                if mine.isEmpty { return group }
                let others = commands.filter { ($0["command"] as? String)?.contains(marker) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    // MARK: The person's own sound hooks

    /// Cues the person already plays a sound for with their own hooks (afplay or say), so the
    /// tab can warn about hearing two sounds.
    func cuesWithOwnSounds() -> Set<SoundCue> {
        guard let json = try? readSettings(), let hooks = json["hooks"] as? [String: Any] else { return [] }
        var found: Set<SoundCue> = []
        for cue in SoundCue.allCases {
            guard let groups = hooks[cue.hookEvent] as? [[String: Any]] else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String
                let matches = matcher == nil || matcher == "" || matcher == "*" || matcher == cue.hookMatcher
                    || (cue.hookMatcher.map { m in matcher?.split(separator: "|").contains { $0 == m } ?? false } ?? false)
                guard matches, let commands = group["hooks"] as? [[String: Any]] else { continue }
                let plays = commands.contains { command in
                    guard let text = command["command"] as? String, !text.contains(Self.marker) else { return false }
                    return text.contains("afplay") || text.contains("say ")
                }
                if plays { found.insert(cue) }
            }
        }
        return found
    }

    // MARK: Sound files

    /// A stable path for the hook to play. Garry's and custom sounds live in Application
    /// Support, so app updates and moves don't break the hooks; system sounds stay where they are.
    func soundPath(for choice: SoundChoice) throws -> String? {
        switch choice {
        case .system(let name):
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        case .custom(let file):
            let url = soundsDirectory.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        case .garry(let id):
            let target = soundsDirectory.appendingPathComponent("\(id).wav")
            guard let source = Self.bundledGarrySound(id) else { return nil }
            try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
            if FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) == false {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            return target.path
        }
    }

    /// Copies a picked audio file in under a unique name and returns the choice for it.
    func importCustomSound(from url: URL) throws -> SoundChoice {
        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        var name = "\(base).\(url.pathExtension.lowercased())"
        var n = 2
        while FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent(name).path) {
            if FileManager.default.contentsEqual(atPath: url.path, andPath: soundsDirectory.appendingPathComponent(name).path) {
                return .custom(name)
            }
            name = "\(base)-\(n).\(url.pathExtension.lowercased())"
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: soundsDirectory.appendingPathComponent(name))
        return .custom(name)
    }

    /// Custom sounds already imported, for the picker.
    func customSounds() -> [SoundChoice] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory.path)) ?? []
        return files.filter { name in !name.hasPrefix(".") && !SoundChoice.bundledPrefixes.contains { name.hasPrefix($0) } }
            .sorted().map { .custom($0) }
    }

    /// Sounds already on this Mac that people tend to use for this: everything in
    /// ~/Library/Sounds, plus files the person's own Claude Code hooks play. Picking one copies
    /// it in (see importCustomSound), so nothing here is shipped with the app.
    func soundsOnThisMac() -> [URL] {
        var found: [URL] = []
        let library = homeDirectory.appendingPathComponent("Library/Sounds")
        found += Self.audioFiles(in: library)
        if let json = try? readSettings(), let hooks = json["hooks"] as? [String: Any] {
            for case let groups as [[String: Any]] in hooks.values {
                for group in groups {
                    for command in (group["hooks"] as? [[String: Any]] ?? []).compactMap({ $0["command"] as? String }) {
                        guard !command.contains(Self.marker) else { continue }
                        found += Self.afplayTargets(in: command, home: homeDirectory)
                    }
                }
            }
        }
        var seen = Set<String>()
        return found.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static let audioExtensions: Set<String> = ["wav", "aiff", "aif", "aifc", "mp3", "m4a", "caf", "aac"]

    static func audioFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { directory.appendingPathComponent($0) }
    }

    /// The files an `afplay` command would play. Shell arithmetic like `$((RANDOM % 3 + 1))`
    /// becomes a wildcard, so every variant is found.
    static func afplayTargets(in command: String, home: URL) -> [URL] {
        var urls: [URL] = []
        // Collapse shell arithmetic first: it has spaces in it.
        let command = command.replacingOccurrences(of: #"\$\(\([^)]*\)\)"#, with: "*", options: .regularExpression)
        for segment in command.components(separatedBy: "afplay").dropFirst() {
            var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)[...]
            while let first = tokens.first, first.hasPrefix("-") {
                tokens = tokens.dropFirst(first.count == 2 ? 2 : 1) // -v 0.5, -t 2, -q 1
            }
            guard var path = tokens.first else { continue }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'&;|"))
            if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
            if path.hasPrefix("$HOME/") { path = home.path + path.dropFirst(5) }
            guard path.hasPrefix("/"), !path.contains("$") else { continue }
            let url = URL(fileURLWithPath: path)
            if path.contains("*") {
                let pattern = url.lastPathComponent
                urls += audioFiles(in: url.deletingLastPathComponent())
                    .filter { NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: $0.lastPathComponent) }
            } else if FileManager.default.fileExists(atPath: path), audioExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls
    }

    static func systemSoundNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    static func bundledGarrySound(_ id: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: id, withExtension: "wav", subdirectory: "Sounds")
        #else
        // The Xcode project flattens resources into Contents/Resources.
        return Bundle.main.url(forResource: id, withExtension: "wav")
        #endif
    }

    // MARK: settings.json

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return json
    }

    private func writeSettings(_ json: [String: Any]) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Keep the person's file as it was before our first change.
        if FileManager.default.fileExists(atPath: settingsURL.path),
           !FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.copyItem(at: settingsURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = settingsURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: settingsURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    // MARK: Preview

    /// Plays a choice right away in the app, at the chosen volume.
    @MainActor
    static func preview(_ entry: SoundCueSettings.Entry, volume: Double, installer: SoundCueInstaller = SoundCueInstaller()) {
        guard let choice = installer.sounds(for: entry).randomElement() else { return }
        preview(choice, volume: volume, installer: installer)
    }

    @MainActor
    static func preview(_ choice: SoundChoice, volume: Double, installer: SoundCueInstaller = SoundCueInstaller()) {
        let url: URL?
        switch choice {
        case .garry(let id): url = bundledGarrySound(id)
        case .system(let name): url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        case .custom(let file): url = installer.soundsDirectory.appendingPathComponent(file)
        }
        guard let url, let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = Float(volume)
        sound.play()
    }
}

extension SoundCueSettings {
    /// Saves these settings and makes every tool's hooks match them; what the Sounds tab and the
    /// setup guide both do on a change. Each tool on its own: a broken file in one mustn't stop
    /// the others. Returns why a tool's hooks couldn't be written, per tool.
    func saveAndInstall(defaults: UserDefaults = .standard,
                        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [SoundTool: String] {
        save(defaults)
        let sounds = SoundCueInstaller(homeDirectory: homeDirectory)
        let installers: [(SoundTool, (SoundCueSettings) throws -> Void)] = [
            (.claude, sounds.apply),
            (.codex, CodexSoundCueInstaller(homeDirectory: homeDirectory, sounds: sounds).apply),
            (.vibe, VibeSoundCueInstaller(homeDirectory: homeDirectory, sounds: sounds).apply),
        ]
        var errors: [SoundTool: String] = [:]
        for (tool, apply) in installers {
            do { try apply(self) } catch { errors[tool] = error.localizedDescription }
        }
        return errors
    }
}
