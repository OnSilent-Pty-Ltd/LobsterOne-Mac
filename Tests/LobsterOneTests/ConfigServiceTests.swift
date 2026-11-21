import Testing
import Foundation
import TOMLKit
@testable import LobsterOne

@Test func readApiKeyFromSettings() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let claudeDir = tmpDir.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

    let settingsJSON = """
    {
        "env": {
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_EXPORTER_OTLP_HEADERS": "x-api-key=rc_abc123"
        }
    }
    """
    try settingsJSON.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.readAPIKey() == "rc_abc123")
}

@Test func readApiKeyFallsBackToBackupConfig() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let lobsteroneDir = tmpDir.appendingPathComponent(".lobsterone")
    try FileManager.default.createDirectory(at: lobsteroneDir, withIntermediateDirectories: true)

    let backupJSON = """
    {"apiKey": "rc_backup456", "configuredAt": "2026-03-16T12:00:00Z"}
    """
    try backupJSON.write(to: lobsteroneDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.readAPIKey() == "rc_backup456")
}

@Test func readApiKeyReturnsNilWhenNoConfig() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.readAPIKey() == nil)
}

@Test func writeConfigMergesIntoExistingSettings() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let claudeDir = tmpDir.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

    let existingJSON = """
    {"env": {"MY_CUSTOM_VAR": "keep_me"}, "someOtherKey": true}
    """
    try existingJSON.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    try config.writeConfig(apiKey: "rc_new789")

    let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let env = json["env"] as! [String: String]

    #expect(env["MY_CUSTOM_VAR"] == "keep_me")
    #expect(env["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1")
    #expect(env["OTEL_EXPORTER_OTLP_HEADERS"] == "x-api-key=rc_new789")
    #expect(env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "https://ingest.lobsterone.ai")
    #expect(json["someOtherKey"] as? Bool == true)
}

@Test func writeConfigCreatesBackup() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)
    try config.writeConfig(apiKey: "rc_new789")

    let backupPath = tmpDir.appendingPathComponent(".lobsterone/config.json")
    let data = try Data(contentsOf: backupPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let sources = json["sources"] as! [String: Any]
    let claude = sources["claude-code"] as! [String: Any]
    #expect(claude["apiKey"] as? String == "rc_new789")
    #expect(claude["configuredAt"] != nil)
}

@Test func readApiKeyFallsBackToMultiSourceBackup() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let lobsteroneDir = tmpDir.appendingPathComponent(".lobsterone")
    try FileManager.default.createDirectory(at: lobsteroneDir, withIntermediateDirectories: true)

    let backupJSON = """
    {"sources": {"claude-code": {"apiKey": "rc_multi123", "configuredAt": "2026-03-26T12:00:00Z"}}}
    """
    try backupJSON.write(to: lobsteroneDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.readAPIKey() == "rc_multi123")
}

@Test func writeCodexConfigWritesToml() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)
    try config.writeCodexConfig(apiKey: "rc_codex789")

    let tomlPath = tmpDir.appendingPathComponent(".codex/config.toml")
    let raw = try String(contentsOf: tomlPath, encoding: .utf8)

    #expect(raw.contains("x-api-key"))
    #expect(raw.contains("rc_codex789"))
    #expect(raw.contains("ingest.lobsterone.ai"))
    #expect(raw.contains("json"))

    // Verify we can read the key back
    #expect(config.readCodexAPIKey() == "rc_codex789")
    #expect(config.isCodexConfigured() == true)
}

@Test func writeCodexConfigDropsTraceExporter() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Config written by an older LobsterOne that enabled the Codex trace exporter
    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let legacyToml = """
    [otel]
    environment = "production"

    [otel.exporter.otlp-http]
    endpoint = "https://ingest.lobsterone.ai/v1/logs"
    protocol = "json"

    [otel.exporter.otlp-http.headers]
    x-api-key = "rc_codex789"

    [otel.trace_exporter.otlp-http]
    endpoint = "https://ingest.lobsterone.ai/v1/traces"
    protocol = "json"
    """
    try legacyToml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.codexConfigNeedsTraceExporterOff() == true)

    try config.writeCodexConfig(apiKey: "rc_codex789")

    let raw = try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)
    #expect(!raw.contains("trace_exporter.otlp-http"))
    #expect(!raw.contains("/v1/traces"))
    #expect(raw.contains("/v1/logs"))
    #expect(config.codexConfigNeedsTraceExporterOff() == false)
    #expect(config.readCodexAPIKey() == "rc_codex789")
}

@Test func writeCodexConfigPinsTraceExporterNone() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Config written by builds 126+ before the explicit "none": no trace_exporter key at all.
    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let toml = """
    [otel]
    environment = "production"

    [otel.exporter.otlp-http]
    endpoint = "https://ingest.lobsterone.ai/v1/logs"
    protocol = "json"

    [otel.exporter.otlp-http.headers]
    x-api-key = "rc_codex789"
    """
    try toml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.codexConfigNeedsTraceExporterOff() == true)

    try config.writeCodexConfig(apiKey: "rc_codex789")

    let table = try TOMLTable(string: String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8))
    #expect(table["otel"]?.table?["trace_exporter"]?.string == "none")
    // Once pinned, launch does not rewrite the file again.
    #expect(config.codexConfigNeedsTraceExporterOff() == false)
}

@Test func codexWithoutOtelSectionIsLeftAlone() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try "model = \"gpt-5\"\n".write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    #expect(ConfigService(homeDirectory: tmpDir).codexConfigNeedsTraceExporterOff() == false)
}

@Test func writeCodexConfigPreservesExistingContent() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

    let existingToml = """
    model = "o3-pro"

    [history]
    persistence = true
    """
    try existingToml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)
    try config.writeCodexConfig(apiKey: "rc_codex789")

    let raw = try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)
    #expect(raw.contains("o3-pro"))
    #expect(raw.contains("rc_codex789"))
}

@Test func removeCodexConfigPreservesOtherSections() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)

    // Write codex config first (creates the file with [otel] section)
    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

    let existingToml = """
    model = "o3-pro"
    """
    try existingToml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    try config.writeCodexConfig(apiKey: "rc_codex789")
    #expect(config.isCodexConfigured() == true)

    try config.removeCodexConfig()
    #expect(config.isCodexConfigured() == false)

    let raw = try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)
    #expect(raw.contains("o3-pro"))
    #expect(!raw.contains("rc_codex789"))
}

@Test func multiSourceBackupPreservesOtherSources() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)

    // Write Claude Code config
    try config.writeConfig(apiKey: "rc_claude123")

    // Write Codex config (should NOT overwrite Claude backup)
    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    try config.writeCodexConfig(apiKey: "rc_codex456")

    // Read backup — both should be present
    let backupPath = tmpDir.appendingPathComponent(".lobsterone/config.json")
    let data = try Data(contentsOf: backupPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let sources = json["sources"] as! [String: Any]

    let claude = sources["claude-code"] as! [String: Any]
    let codex = sources["codex"] as! [String: Any]
    #expect(claude["apiKey"] as? String == "rc_claude123")
    #expect(codex["apiKey"] as? String == "rc_codex456")
}

@Test func removeConfigPreservesOtherSettings() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = ConfigService(homeDirectory: tmpDir)
    try config.writeConfig(apiKey: "rc_toremove")

    let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
    var data = try Data(contentsOf: settingsPath)
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var env = json["env"] as! [String: String]
    env["MY_CUSTOM_VAR"] = "keep_me"
    json["env"] = env
    data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsPath)

    try config.removeConfig()

    data = try Data(contentsOf: settingsPath)
    json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    env = json["env"] as! [String: String]
    #expect(env["MY_CUSTOM_VAR"] == "keep_me")
    #expect(env["CLAUDE_CODE_ENABLE_TELEMETRY"] == nil)
    #expect(env["OTEL_EXPORTER_OTLP_HEADERS"] == nil)
}

@Test func isVibeInstalledDetectsSessionsDir() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sessionsDir = tmpDir.appendingPathComponent(".vibe/sessions")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let config = ConfigService(homeDirectory: tmpDir)
    #expect(config.isVibeInstalled() == true)
}

@Test func isVibeInstalledFalseWithoutSessionsDir() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // No ~/.vibe/sessions dir. isVibeInstalled also falls back to a `which vibe`
    // PATH probe; only assert the false case when no vibe binary is on PATH so the
    // dir-detection branch is what's under test (deterministic on CI).
    let probe = Process()
    probe.launchPath = "/usr/bin/env"
    probe.arguments = ["which", "vibe"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    try? probe.run()
    probe.waitUntilExit()
    let vibeOnPath = probe.terminationStatus == 0

    let config = ConfigService(homeDirectory: tmpDir)
    if !vibeOnPath {
        #expect(config.isVibeInstalled() == false)
    }
}

// MARK: - settings.json is never clobbered

private func claudeHome(_ settings: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    if let settings {
        try settings.write(to: dir.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func writeConfigLeavesABrokenSettingsFileAlone() throws {
    let broken = """
    {
      // my model
      "model": "opus",
      "hooks": {},
    }
    """
    let home = try claudeHome(broken)
    defer { try? FileManager.default.removeItem(at: home) }
    let config = ConfigService(homeDirectory: home)

    #expect(throws: ConfigService.ConfigError.unreadableClaudeSettings) { try config.writeConfig(apiKey: "rc_new") }
    #expect(throws: ConfigService.ConfigError.unreadableClaudeSettings) { try config.removeConfig() }
    let after = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
    #expect(after == broken)
}

@Test func writeConfigKeepsEverythingElseAndBacksUpOnce() throws {
    let original = """
    {"model": "opus", "env": {"MY_FLAG": "1", "MAX_TOKENS": 4096, "VERBOSE": true},
     "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay /x.wav &"}]}]}}
    """
    let home = try claudeHome(original)
    defer { try? FileManager.default.removeItem(at: home) }
    let config = ConfigService(homeDirectory: home)

    try config.writeConfig(apiKey: "rc_first")
    try config.writeConfig(apiKey: "rc_second")

    let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["model"] as? String == "opus")
    #expect(json["hooks"] != nil)
    let env = try #require(json["env"] as? [String: Any])
    #expect(env["MY_FLAG"] as? String == "1")
    #expect(env["MAX_TOKENS"] as? Int == 4096)
    #expect(env["VERBOSE"] as? Bool == true)
    #expect(env["OTEL_EXPORTER_OTLP_HEADERS"] as? String == "x-api-key=rc_second")
    #expect(config.readAPIKey() == "rc_second")
    #expect(config.checkClaudeCodeOtel().configured)

    // The backup is the file as it was before the first change, not after.
    let backup = try String(contentsOf: home.appendingPathComponent(".claude/settings.json.lobsterone-backup"), encoding: .utf8)
    #expect(backup == original)

    try config.removeConfig()
    let removed = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))) as? [String: Any])
    let removedEnv = try #require(removed["env"] as? [String: Any])
    #expect(removedEnv["OTEL_EXPORTER_OTLP_HEADERS"] == nil)
    #expect(removedEnv["MAX_TOKENS"] as? Int == 4096)
}

@Test func writeConfigTreatsAnEmptySettingsFileAsNew() throws {
    let home = try claudeHome("\n")
    defer { try? FileManager.default.removeItem(at: home) }
    let config = ConfigService(homeDirectory: home)
    try config.writeConfig(apiKey: "rc_fresh")
    #expect(config.readAPIKey() == "rc_fresh")
}
