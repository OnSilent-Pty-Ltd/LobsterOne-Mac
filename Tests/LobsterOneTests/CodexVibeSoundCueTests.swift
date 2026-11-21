import Testing
import Foundation
import TOMLKit
@testable import LobsterOne

private func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sound-cues-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Sounds on, playing in `tool`, with distinct system sounds so a log tells the moments apart.
private func cues(in tool: SoundTool) -> SoundCueSettings {
    var settings = SoundCueSettings()
    settings.enabled = true
    settings.tools = [tool]
    settings.cues[.sessionStart] = .init(on: true, sound: .system("Basso"))
    settings.cues[.needsPermission] = .init(on: true, sound: .system("Ping"))
    settings.cues[.waiting] = .init(on: true, sound: .system("Glass"))
    settings.cues[.finished] = .init(on: true, sound: .system("Hero"))
    settings.cues[.planApproved] = .init(on: true, sound: .system("Pop"))
    return settings
}

/// A stand-in afplay on the PATH that logs what it was asked to play.
private struct FakeAfplay {
    let bin: URL
    let log: URL

    init(in home: URL) throws {
        bin = home.appendingPathComponent("fake-bin")
        log = home.appendingPathComponent("afplay.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("afplay")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$AFPLAY_LOG\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    var played: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// Runs a shell command the way a tool's hook would, with this afplay and `home` as HOME.
    @discardableResult
    func run(_ args: [String], shell: String = "/bin/sh", home: URL, stdin: String = "") throws -> (status: Int32, out: String) {
        let process = Process(), out = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "AFPLAY_LOG": log.path]
        process.standardOutput = out
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Waits for background sounds to land in the log.
    func settle(_ seconds: Double = 0.4) { Thread.sleep(forTimeInterval: seconds) }

    /// Waits until `sound` has played `times` times (tests run in parallel, so a busy machine
    /// may take a while to start the background afplay). True when it got there.
    @discardableResult
    func waitFor(_ sound: String, times: Int = 1, timeout: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if played.components(separatedBy: sound).count - 1 >= times { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

// MARK: - Codex

private func codexHooks(_ home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent(".codex/hooks.json"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func codexCommands(_ json: [String: Any], _ event: String) -> [String] {
    let groups = (json["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

private let ownCodexHooks = """
{
  "description": "mine",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
  }
}
"""

@Test func codexHooksAreStableWhateverTheCues() throws {
    let home = try tempHome()
    let codex = CodexSoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .codex)
    try codex.apply(settings)
    let first = try Data(contentsOf: codex.hooksURL)

    let json = try codexHooks(home)
    for script in CodexSoundCueInstaller.Script.allCases {
        #expect(codexCommands(json, script.event) == [script.declaration], "\(script.event)")
    }
    let start = try #require(((json["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.first)
    #expect(start["matcher"] as? String == "^startup$")
    #expect(Set(json.keys) == ["hooks"])
    let perms = try FileManager.default.attributesOfItem(atPath: codex.hooksURL.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    for script in CodexSoundCueInstaller.Script.allCases {
        #expect(FileManager.default.fileExists(atPath: codex.scriptURL(script).path))
    }

    // Applying again, switching moments off, changing sounds and adding quiet times: the
    // declarations Codex trusted stay byte for byte; only the scripts change.
    try codex.apply(settings)
    settings.cues[.finished]?.on = false
    settings.cues[.waiting]?.on = false
    settings.cues[.needsPermission]?.sound = .system("Funk")
    settings.quietTimes = [QuietTime()]
    try codex.apply(settings)
    #expect(try Data(contentsOf: codex.hooksURL) == first)
    #expect(!FileManager.default.fileExists(atPath: codex.scriptURL(.stop).path))
    #expect(try String(contentsOf: codex.scriptURL(.permissionRequest), encoding: .utf8).contains("Funk.aiff"))

    // Every moment off: still declared, but no scripts at all.
    for cue in SoundCue.allCases { settings.cues[cue]?.on = false }
    try codex.apply(settings)
    #expect(try Data(contentsOf: codex.hooksURL) == first)
    for script in CodexSoundCueInstaller.Script.allCases {
        #expect(!FileManager.default.fileExists(atPath: codex.scriptURL(script).path))
    }

    // Codex sounds off: the file we created goes away.
    settings.tools = [.claude]
    try codex.apply(settings)
    #expect(!FileManager.default.fileExists(atPath: codex.hooksURL.path))
}

@Test func codexKeepsThePersonsOwnHooks() throws {
    let home = try tempHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let url = home.appendingPathComponent(".codex/hooks.json")
    try ownCodexHooks.write(to: url, atomically: true, encoding: .utf8)
    let codex = CodexSoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .codex)
    try codex.apply(settings)

    var json = try codexHooks(home)
    #expect(json["description"] as? String == "mine")
    #expect(codexCommands(json, "Stop") == ["say done", CodexSoundCueInstaller.Script.stop.declaration])
    let backup = try String(contentsOf: home.appendingPathComponent(".codex/hooks.json.lobsterone-backup"), encoding: .utf8)
    #expect(backup == ownCodexHooks)

    settings.enabled = false
    try codex.apply(settings)
    json = try codexHooks(home)
    #expect(json["description"] as? String == "mine")
    #expect(codexCommands(json, "Stop") == ["say done"])
    #expect((json["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
    #expect(!FileManager.default.fileExists(atPath: codex.scriptURL(.stop).path))
}

@Test func codexLeavesABrokenHooksFileAlone() throws {
    let home = try tempHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let url = home.appendingPathComponent(".codex/hooks.json")
    let broken = "{ \"hooks\": { // no\n } }"
    try broken.write(to: url, atomically: true, encoding: .utf8)
    let codex = CodexSoundCueInstaller(homeDirectory: home)
    #expect(throws: CodexSoundCueInstaller.Failure.self) { try codex.apply(cues(in: .codex)) }
    #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    // With Codex sounds off there's nothing of ours in it, so it isn't even read.
    try codex.apply(cues(in: .claude))
    #expect(try String(contentsOf: url, encoding: .utf8) == broken)
}

@Test func codexDeclarationRunsTheScriptQuietly() throws {
    let home = try tempHome()
    let fake = try FakeAfplay(in: home)
    let codex = CodexSoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .codex)
    try codex.apply(settings)

    // Codex runs `$SHELL -lc <command>`; a PermissionRequest hook must print nothing.
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
        let result = try fake.run(["-c", CodexSoundCueInstaller.Script.permissionRequest.declaration], shell: shell, home: home, stdin: "{}")
        #expect(result.status == 0 && result.out.isEmpty, "\(shell): \(result)")
    }
    #expect(fake.waitFor("Ping.aiff", times: 3))

    // A moment that's off has no script: the hook does nothing and still succeeds.
    settings.cues[.needsPermission]?.on = false
    try codex.apply(settings)
    let result = try fake.run(["-c", CodexSoundCueInstaller.Script.permissionRequest.declaration], home: home)
    #expect(result.status == 0 && result.out.isEmpty)
}

@Test func codexPlanApprovedPlaysOnlyForThePlanPrompts() throws {
    let home = try tempHome()
    let fake = try FakeAfplay(in: home)
    let codex = CodexSoundCueInstaller(homeDirectory: home)
    try codex.apply(cues(in: .codex))
    let script = codex.scriptURL(.userPromptSubmit).path

    let prompts = [
        (#"{"session_id":"a","prompt":"Implement the plan.","cwd":"/x"}"#, true),
        (#"{"session_id":"a","prompt":"Read the approved plan at /tmp/my plan.md and implement it.","cwd":"/x"}"#, true),
        (#"{"session_id":"a","prompt":"Implement the plan. Then also fix the tests.","cwd":"/x"}"#, false),
        (#"{"session_id":"a","prompt":"please refactor","cwd":"/x"}"#, false),
    ]
    for (input, plays) in prompts {
        try? FileManager.default.removeItem(at: fake.log)
        let result = try fake.run([script], home: home, stdin: input)
        #expect(result.status == 0)
        if plays {
            #expect(fake.waitFor("Pop.aiff"), "\(input)")
        } else {
            fake.settle(0.8)
            #expect(!fake.played.contains("Pop.aiff"), "\(input)")
        }
    }
}

@Test func codexWaitingPlaysAfterTheDelayUnlessYouReply() throws {
    let home = try tempHome()
    let fake = try FakeAfplay(in: home)
    let codex = CodexSoundCueInstaller(homeDirectory: home, waitingDelay: 1)
    try codex.apply(cues(in: .codex))
    let stop = codex.scriptURL(.stop).path, prompt = codex.scriptURL(.userPromptSubmit).path
    #expect(try String(contentsOf: codex.scriptURL(.stop), encoding: .utf8).contains("sleep 1\n"))

    // Turn ends, nobody replies: finished now, waiting a second later.
    let ended = Date()
    try fake.run([stop], home: home)
    #expect(fake.waitFor("Hero.aiff"))
    if Date().timeIntervalSince(ended) < 0.8 { #expect(!fake.played.contains("Glass.aiff")) }
    #expect(fake.waitFor("Glass.aiff"))

    // Turn ends, the person replies straight away: no waiting sound.
    try FileManager.default.removeItem(at: fake.log)
    try fake.run([stop], home: home)
    try fake.run([prompt], home: home, stdin: #"{"prompt":"thanks"}"#)
    #expect(fake.waitFor("Hero.aiff"))
    fake.settle(2)
    #expect(!fake.played.contains("Glass.aiff"))

    // Two turns in a row: only the latest timer plays.
    try FileManager.default.removeItem(at: fake.log)
    try fake.run([stop], home: home)
    fake.settle(0.5)
    try fake.run([stop], home: home)
    #expect(fake.waitFor("Glass.aiff"))
    fake.settle(1.5)
    #expect(fake.played.components(separatedBy: "Glass.aiff").count - 1 == 1)

    // A new session cancels too, and cancelling with no stamp yet doesn't fail.
    try FileManager.default.removeItem(at: fake.log)
    #expect(try fake.run([codex.scriptURL(.sessionStart).path], home: home).status == 0)
    try fake.run([stop], home: home)
    try fake.run([codex.scriptURL(.sessionStart).path], home: home)
    fake.settle(1.8)
    #expect(!fake.played.contains("Glass.aiff"))
}

// MARK: - Vibe

private let ownVibeHooks = """
# my hooks
[[hooks]]
name = "notify-me"
type = "notification"
command = "say hi"

"""

private func vibeText(_ home: URL) throws -> String {
    try String(contentsOf: home.appendingPathComponent(".vibe/hooks.toml"), encoding: .utf8)
}

@Test func vibeBlockIsWrittenReplacedAndRemoved() throws {
    let home = try tempHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".vibe"), withIntermediateDirectories: true)
    try ownVibeHooks.write(to: home.appendingPathComponent(".vibe/hooks.toml"), atomically: true, encoding: .utf8)
    let vibe = VibeSoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .vibe)
    try vibe.apply(settings)

    let text = try vibeText(home)
    #expect(text.hasPrefix(ownVibeHooks))
    #expect(text.hasSuffix(VibeSoundCueInstaller.endMarker + "\n"))
    for name in ["lobsterone-session-start", "lobsterone-needs-permission", "lobsterone-waiting", "lobsterone-finished"] {
        #expect(text.contains("name = \"\(name)\""))
    }
    #expect(!text.contains("Pop.aiff")) // plan approved: Vibe has no plan mode
    #expect(text.contains("match = \"question_asked\"") && text.contains("timeout = 10.0"))
    // Every command waits for its sound: Vibe kills what a hook leaves behind.
    #expect(!text.contains("2>&1 &"))

    // The whole file is valid TOML with the tables Vibe expects.
    let table = try TOMLTable(string: text)
    let hooks = try #require(table["hooks"]?.array)
    #expect(hooks.count == 5)
    let finished = try #require(hooks.compactMap(\.table).first { $0["name"]?.string == "lobsterone-finished" })
    #expect(finished["type"]?.string == "notification" && finished["match"]?.string == "turn_completed")
    #expect(finished["command"]?.string?.hasPrefix("afplay -v 0.60 '/System/Library/Sounds/Hero.aiff'") == true)

    // Applying again changes nothing; a change replaces the block in place.
    try vibe.apply(settings)
    #expect(try vibeText(home) == text)
    settings.cues[.sessionStart]?.on = false
    try vibe.apply(settings)
    let fewer = try vibeText(home)
    #expect(fewer.hasPrefix(ownVibeHooks) && !fewer.contains("lobsterone-session-start"))
    #expect(fewer.components(separatedBy: VibeSoundCueInstaller.beginMarker).count == 2)

    // Off: the person's file is back to exactly what it was.
    settings.tools = [.claude]
    try vibe.apply(settings)
    #expect(try vibeText(home) == ownVibeHooks)
    #expect(try String(contentsOf: home.appendingPathComponent(".vibe/hooks.toml.lobsterone-backup"), encoding: .utf8) == ownVibeHooks)
}

@Test func vibeFileWeCreatedIsRemovedWhenEmpty() throws {
    let home = try tempHome()
    let vibe = VibeSoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .vibe)
    try vibe.apply(settings)
    let url = home.appendingPathComponent(".vibe/hooks.toml")
    #expect(try vibeText(home).hasPrefix(VibeSoundCueInstaller.beginMarker))
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    // No moment Vibe can play is on: no block, and the empty file goes.
    for cue in SoundCue.allCases where cue != .planApproved { settings.cues[cue]?.on = false }
    try vibe.apply(settings)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func vibeRefusesABlockThatsBeenTamperedWith() throws {
    let home = try tempHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".vibe"), withIntermediateDirectories: true)
    let url = home.appendingPathComponent(".vibe/hooks.toml")
    let begin = VibeSoundCueInstaller.beginMarker, end = VibeSoundCueInstaller.endMarker
    let cases: [(String, VibeSoundCueInstaller.Failure)] = [
        ("\(begin)\n[[hooks]]\nname = \"x\"\n", .brokenBlock),
        ("[[hooks]]\nname = \"x\"\n\(end)\n", .brokenBlock),
        ("\(end)\n\(begin)\n", .brokenBlock),
        ("\(begin)\n\(end)\n\(begin)\n\(end)\n", .brokenBlock),
        ("[[hooks]]\nname = \"lobsterone-finished\"\ntype = \"notification\"\ncommand = \"x\"\n", .nameOutsideBlock),
    ]
    for (text, failure) in cases {
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: failure) { try VibeSoundCueInstaller(homeDirectory: home).apply(cues(in: .vibe)) }
        #expect(try vibeText(home) == text)
    }
    // A file with nothing of ours in it is left alone while Vibe sounds are off, whatever it holds.
    try "not = [toml".write(to: url, atomically: true, encoding: .utf8)
    try VibeSoundCueInstaller(homeDirectory: home).apply(cues(in: .claude))
    #expect(try vibeText(home) == "not = [toml")
}

@Test func vibeCommandsAreEscapedForTOML() throws {
    #expect(VibeSoundCueInstaller.tomlString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    #expect(VibeSoundCueInstaller.tomlString("x\ny\t\u{1}\u{7F}") == #""x\ny\t\u0001\u007F""#)
    // A real command, with quoted paths, random pick and quiet hours, survives the round trip.
    let command = SoundCueInstaller.command(paths: ["/a b/it's-1.wav", "/a b/it's-2.wav"], volume: 0.5,
                                            quiet: [QuietTime()], background: false)
    let block = try #require(VibeSoundCueInstaller.block([.finished: command]))
    let table = try TOMLTable(string: block)
    #expect(table["hooks"]?.array?.first?.table?["command"]?.string == command)
}

@Test func vibeForegroundCommandPlaysAndRespectsQuietTimes() throws {
    let night = QuietTime(start: 22 * 60, end: 8 * 60)
    for paths in [["/a/one.wav"], ["/a/x-1.wav", "/a/x-2.wav"]] {
        let command = SoundCueInstaller.command(paths: paths, volume: 1, quiet: [night], background: false)
        #expect(!command.contains("2>&1 &"))
        #expect(command.hasSuffix(SoundCueInstaller.marker))
        for (clock, plays) in [("0000", false), ("0759", false), ("0800", true), ("2159", true), ("2200", false)] {
            let pinned = command.replacingOccurrences(of: "$(date +%H%M)", with: clock)
                .replacingOccurrences(of: "afplay -v 1.00", with: "echo played")
                .replacingOccurrences(of: " >/dev/null 2>&1;", with: ";")
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", pinned]
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(process.terminationStatus == 0, "\(shell) \(clock)")
                #expect(out.contains("played") == plays, "\(shell) at \(clock): \(out)")
            }
        }
    }
    // Without quiet times it still waits for the sound and exits cleanly, even when afplay fails.
    let plain = SoundCueInstaller.command(paths: ["/nowhere.wav"], volume: 1, background: false)
    #expect(plain == "afplay -v 1.00 '/nowhere.wav' >/dev/null 2>&1; exit 0; # lobsterone-sound-cue")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", plain]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

// MARK: - Settings

@Test func savedSoundSettingsFromBeforeToolsPlayInClaudeOnly() throws {
    let old = #"{"enabled":true,"volume":0.4,"cues":["finished",{"on":true,"sound":{"system":{"_0":"Ping"}}}],"quietTimes":[]}"#
    let loaded = try JSONDecoder().decode(SoundCueSettings.self, from: Data(old.utf8))
    #expect(loaded.tools == [.claude])
    #expect(loaded.plays(in: .claude) && !loaded.plays(in: .codex) && !loaded.plays(in: .vibe))
    var roundTrip = loaded
    roundTrip.tools = [.codex, .vibe]
    let again = try JSONDecoder().decode(SoundCueSettings.self, from: JSONEncoder().encode(roundTrip))
    #expect(again.tools == [.codex, .vibe])
}

@Test func claudeHooksFollowTheClaudeSwitch() throws {
    let home = try tempHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let installer = SoundCueInstaller(homeDirectory: home)
    var settings = cues(in: .claude)
    try installer.apply(settings)
    let url = home.appendingPathComponent(".claude/settings.json")
    #expect(try String(contentsOf: url, encoding: .utf8).contains(SoundCueInstaller.marker))
    settings.tools = [.codex]
    try installer.apply(settings)
    #expect(try !String(contentsOf: url, encoding: .utf8).contains(SoundCueInstaller.marker))
}
