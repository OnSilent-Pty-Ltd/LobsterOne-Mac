import Testing
import AVFoundation
import Foundation
@testable import LobsterOne

private func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sound-cues-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    return dir
}

private func settings(_ home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func commands(_ json: [String: Any], _ event: String) -> [String] {
    let groups = (json["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

/// The person's own setup, like the one this feature was modelled on.
private let ownHooks = """
{
  "env": {"FOO": "1"},
  "hooks": {
    "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "afplay ~/Library/Sounds/input-1.wav &"}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "afplay ~/Library/Sounds/hello-1.wav &"}]}]
  }
}
"""

@Test func soundCuesKeepTheirOwnHooksAndReplaceOurs() throws {
    let home = try tempHome()
    try ownHooks.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    let installer = SoundCueInstaller(homeDirectory: home)
    var cues = SoundCueSettings()
    cues.enabled = true
    cues.cues[.needsPermission] = .init(on: true, sound: .system("Ping"))

    try installer.apply(cues)
    try installer.apply(cues) // applying twice must not duplicate

    let json = try settings(home)
    #expect((json["env"] as? [String: String])?["FOO"] == "1")
    let notification = commands(json, "Notification")
    #expect(notification.contains("afplay ~/Library/Sounds/input-1.wav &"))
    #expect(notification.filter { $0.contains(SoundCueInstaller.marker) }.count == 2) // permission + waiting
    #expect(commands(json, "Stop").count == 1)
    #expect(commands(json, "SessionStart") == ["afplay ~/Library/Sounds/hello-1.wav &"]) // off by default
    // The original is kept once, untouched.
    let backup = try String(contentsOf: home.appendingPathComponent(".claude/settings.json.lobsterone-backup"), encoding: .utf8)
    #expect(backup == ownHooks)
}

@Test func turningSoundsOffRemovesOnlyOurHooks() throws {
    let home = try tempHome()
    try ownHooks.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    let installer = SoundCueInstaller(homeDirectory: home)
    var cues = SoundCueSettings()
    cues.enabled = true
    try installer.apply(cues)
    cues.enabled = false
    try installer.apply(cues)

    let json = try settings(home)
    #expect(commands(json, "Notification") == ["afplay ~/Library/Sounds/input-1.wav &"])
    #expect(commands(json, "Stop").isEmpty)
    #expect((json["hooks"] as? [String: Any])?["Stop"] == nil)
}

@Test func soundCuesLeaveABrokenSettingsFileAlone() throws {
    let home = try tempHome()
    let broken = "{ \"env\": { // a comment\n } }"
    try broken.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    var cues = SoundCueSettings()
    cues.enabled = true
    #expect(throws: SoundCueInstaller.Failure.self) { try SoundCueInstaller(homeDirectory: home).apply(cues) }
    #expect(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == broken)
}

@Test func soundCuesSpotTheirOwnSoundHooks() throws {
    let home = try tempHome()
    try ownHooks.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    let found = SoundCueInstaller(homeDirectory: home).cuesWithOwnSounds()
    #expect(found == [.needsPermission, .sessionStart])
}

@Test func soundCueCommandQuotesPaths() {
    let command = SoundCueInstaller.command(path: "/Users/a b/it's.wav", volume: 0.5)
    #expect(command == "afplay -v 0.50 '/Users/a b/it'\\''s.wav' >/dev/null 2>&1 & # lobsterone-sound-cue")
}

@Test func garrySoundsAreBundled() {
    for sound in SoundChoice.bundledSets.flatMap(\.sounds) {
        #expect(SoundCueInstaller.bundledGarrySound(sound.id) != nil)
    }
}

@Test func soundsOnThisMacFindsLibrarySoundsAndHookTargets() throws {
    let home = try tempHome()
    let library = home.appendingPathComponent("Library/Sounds")
    let elsewhere = home.appendingPathComponent("tunes")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    for name in ["hello-1.wav", "hello-2.wav", "notes.txt"] {
        try Data([0]).write(to: library.appendingPathComponent(name))
    }
    for name in ["ping-1.aiff", "ping-2.aiff", "other.aiff"] {
        try Data([0]).write(to: elsewhere.appendingPathComponent(name))
    }
    let json = """
    {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay -v 0.4 ~/tunes/ping-$((RANDOM % 2 + 1)).aiff &"}]}]}}
    """
    try json.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)

    let names = SoundCueInstaller(homeDirectory: home).soundsOnThisMac().map(\.lastPathComponent)
    #expect(names == ["hello-1.wav", "hello-2.wav", "ping-1.aiff", "ping-2.aiff"])
}

@Test func everyBundledSoundIsShortEnough() throws {
    for sound in SoundChoice.bundledSets.flatMap(\.sounds) {
        let url = try #require(SoundCueInstaller.bundledGarrySound(sound.id))
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(seconds <= (sound.id == "mission-computers" ? 4.5 : 2.1), "\(sound.id) is \(seconds)s")
    }
}

@Test func numberedSoundsPlayAtRandomByDefault() throws {
    let home = try tempHome()
    let installer = SoundCueInstaller(homeDirectory: home)
    var cues = SoundCueSettings()
    cues.enabled = true
    cues.cues[.sessionStart] = .init(on: true, sound: .garry("classic-hello-2"))
    cues.cues[.finished] = .init(on: true, sound: .garry("classic-on-it-1"), random: false, level: 0.5)
    try installer.apply(cues)

    let json = try settings(home)
    let start = try #require(commands(json, "SessionStart").first)
    for n in 1...5 { #expect(start.contains("classic-hello-\(n).wav'")) }
    #expect(start.contains("shift $((RANDOM % 5))"))
    // Random off: the one sound, at this moment's own level (0.6 main x 0.5).
    let stop = try #require(commands(json, "Stop").first)
    #expect(stop.hasPrefix("afplay -v 0.30 '"))
    #expect(stop.contains("classic-on-it-1.wav'") && !stop.contains("classic-on-it-2"))
    // A sound with no numbered siblings is played as before.
    let permission = try #require(commands(json, "Notification").first { $0.contains("garry-knock") })
    #expect(permission.hasPrefix("afplay "))
}

@Test func randomCommandPlaysEveryVersionAndNothingElse() throws {
    // Run the real hook command in the shells Claude Code may use, with afplay swapped for echo.
    let command = SoundCueInstaller.command(paths: ["/a b/it's-1.wav", "/a b/it's-2.wav", "/a b/it's-3.wav"], volume: 1)
        .replacingOccurrences(of: "afplay -v 1.00", with: "echo")
        .replacingOccurrences(of: " >/dev/null 2>&1 &", with: ";")
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
        var heard = Set<String>()
        for _ in 0..<60 {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", command]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            heard.insert(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(heard == ["/a b/it's-1.wav", "/a b/it's-2.wav", "/a b/it's-3.wav"], "\(shell): \(heard)")
    }
}

@Test func soundVariantsGroupNumberedFilesOnly() {
    let custom: [SoundChoice] = [.custom("hello-1.wav"), .custom("hello-2.mp3"), .custom("hello-10.wav"),
                                 .custom("input-1.wav"), .custom("ding.wav"), .custom("ding-2.wav")]
    #expect(SoundChoice.variants(of: .custom("hello-10.wav"), custom: custom)
        == [.custom("hello-1.wav"), .custom("hello-2.mp3"), .custom("hello-10.wav")])
    #expect(SoundChoice.variants(of: .custom("input-1.wav"), custom: custom) == [.custom("input-1.wav")])
    #expect(SoundChoice.variants(of: .custom("ding.wav"), custom: custom) == [.custom("ding.wav")])
    #expect(SoundChoice.variants(of: .garry("garry-ta-da"), custom: custom) == [.garry("garry-ta-da")])
    #expect(SoundChoice.variants(of: .system("Ping"), custom: custom) == [.system("Ping")])
}

@Test func savedSoundSettingsFromBeforeRandomStillLoad() throws {
    let old = #"{"on":true,"sound":{"garry":{"_0":"classic-hello-1"}}}"#
    let entry = try JSONDecoder().decode(SoundCueSettings.Entry.self, from: Data(old.utf8))
    #expect(entry == .init(on: true, sound: .garry("classic-hello-1"), random: true, level: 1))
}

@Test func savedChoicesFollowSoundsThatBecameNumbered() throws {
    let suite = "sound-cues-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old = #"{"enabled":true,"volume":0.6,"cues":["finished",{"on":true,"sound":{"garry":{"_0":"garry-done"}}}]}"#
    defaults.set(Data(old.utf8), forKey: SoundCueSettings.defaultsKey)
    #expect(SoundCueSettings.load(defaults).entry(.finished).sound == .garry("garry-done-1"))
}

@Test func everyPackCoversEveryMomentWithBundledSounds() {
    let bundled = Set(SoundChoice.bundledSets.flatMap(\.sounds).map(\.id))
    #expect(Set(SoundPack.all.map(\.id)).count == SoundPack.all.count)
    for pack in SoundPack.all {
        #expect(pack.ids.count == SoundCue.allCases.count, "\(pack.id)")
        #expect(pack.ids.allSatisfy(bundled.contains), "\(pack.id)")
    }
}

@Test func applyingAPackKeepsSwitchesAndLevels() throws {
    var cues = SoundCueSettings()
    #expect(cues.pack?.id == "garry") // the defaults are a pack
    cues.cues[.finished] = .init(on: false, sound: .system("Ping"), random: false, level: 0.4)
    #expect(cues.pack == nil)

    let apollo = try #require(SoundPack.all.first { $0.id == "apollo" })
    cues.apply(apollo)
    #expect(cues.pack?.id == "apollo")
    #expect(cues.entry(.finished) == .init(on: false, sound: .garry("mission-eagle-landed"), random: true, level: 0.4))
    #expect(cues.entry(.sessionStart).on == false && cues.entry(.needsPermission).on)

    // Picking another take of a numbered sound, with random on, is still the same pack.
    cues.apply(try #require(SoundPack.all.first { $0.id == "garry" }))
    cues.cues[.waiting]?.sound = .garry("garry-nudge-3")
    #expect(cues.pack?.id == "garry")
    cues.cues[.waiting]?.random = false
    #expect(cues.pack == nil)
}

@Test func quietTimesSilenceTheHookAtTheRightHours() throws {
    let night = QuietTime(start: 22 * 60, end: 8 * 60), lunch = QuietTime(start: 12 * 60 + 30, end: 13 * 60 + 30)
    #expect(night.contains(minute: 23 * 60) && night.contains(minute: 7 * 60 + 59) && !night.contains(minute: 8 * 60))
    // Run the real hook command with the clock pinned and afplay swapped for echo.
    for paths in [["/a/one.wav"], ["/a/x-1.wav", "/a/x-2.wav"]] {
        let command = SoundCueInstaller.command(paths: paths, volume: 1, quiet: [night, lunch])
        #expect(command.hasSuffix(SoundCueInstaller.marker))
        for (clock, plays) in [("0000", false), ("0759", false), ("0800", true), ("0900", true), ("1229", true),
                               ("1230", false), ("1329", false), ("1330", true), ("2159", true), ("2200", false), ("2359", false)] {
            let pinned = command.replacingOccurrences(of: "$(date +%H%M)", with: clock)
                .replacingOccurrences(of: "afplay -v 1.00", with: "echo played")
                .replacingOccurrences(of: " >/dev/null 2>&1 &", with: ";")
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
    // No quiet times: the command is exactly what it was.
    #expect(SoundCueInstaller.command(paths: ["/a/one.wav"], volume: 1) == "afplay -v 1.00 '/a/one.wav' >/dev/null 2>&1 & # lobsterone-sound-cue")
}

@Test func savedSoundSettingsFromBeforeQuietTimesStillLoad() throws {
    let old = #"{"enabled":true,"volume":0.4,"cues":["finished",{"on":false,"sound":{"system":{"_0":"Ping"}}}]}"#
    let loaded = try JSONDecoder().decode(SoundCueSettings.self, from: Data(old.utf8))
    #expect(loaded.enabled && loaded.volume == 0.4 && loaded.quietTimes.isEmpty)
    #expect(loaded.entry(.finished).on == false)
}
