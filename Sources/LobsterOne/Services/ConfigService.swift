import Foundation
import TOMLKit

final class ConfigService {
    enum ConfigError: LocalizedError, Equatable {
        /// ~/.claude/settings.json exists but isn't valid JSON (a comment, a trailing comma...).
        case unreadableClaudeSettings

        var errorDescription: String? {
            switch self {
            case .unreadableClaudeSettings:
                "Your Claude Code settings file (~/.claude/settings.json) isn't valid JSON, so LobsterOne left it alone rather than risk your other settings. Fix the file, then try again."
            }
        }
    }

    private let homeDirectory: URL
    private static let ingestURL = Constants.ingestURL

    private var settingsPath: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    private var codexConfigPath: URL {
        homeDirectory.appendingPathComponent(".codex/config.toml")
    }

    /// The person's settings.json as it was before LobsterOne first changed it.
    private var settingsBackupPath: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json.lobsterone-backup")
    }

    private var backupPath: URL {
        homeDirectory.appendingPathComponent(".lobsterone/config.json")
    }

    private static let otelKeys: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "OTEL_METRICS_EXPORTER": "otlp",
        "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_ENDPOINT": ingestURL,
    ]

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.homeDirectory = homeDirectory
    }

    // MARK: - Claude Code config

    func readAPIKey() -> String? {
        if let key = readAPIKeyFromSettings() { return key }
        return readAPIKeyFromBackup()
    }

    func writeConfig(apiKey: String) throws {
        try writeSettingsJSON(apiKey: apiKey)
        try writeSourceBackup(sourceType: "claude-code", apiKey: apiKey)
    }

    func removeConfig() throws {
        try removeFromSettingsJSON()
        removeSourceBackup(sourceType: "claude-code")
    }

    func isClaudeCodeInstalled() -> Bool {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        if FileManager.default.fileExists(atPath: claudeDir.path) { return true }
        let p = Process(); p.launchPath = "/usr/bin/env"; p.arguments = ["which", "claude"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    // MARK: - Codex config

    func isCodexInstalled() -> Bool {
        let codexDir = homeDirectory.appendingPathComponent(".codex")
        if FileManager.default.fileExists(atPath: codexDir.path) { return true }
        // Check if codex command is available
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["which", "codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func isCodexConfigured() -> Bool {
        readCodexAPIKey() != nil
    }

    func readCodexAPIKey() -> String? {
        guard let raw = try? String(contentsOf: codexConfigPath, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let otel = table["otel"]?.table,
              let exporter = otel["exporter"]?.table,
              let otlpHttp = exporter["otlp-http"]?.table,
              let headers = otlpHttp["headers"]?.table,
              let key = headers["x-api-key"]?.string,
              key.hasPrefix("rc_") else {
            return nil
        }
        return key
    }

    func writeCodexConfig(apiKey: String) throws {
        let codexDir = homeDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        var table: TOMLTable
        if let raw = try? String(contentsOf: codexConfigPath, encoding: .utf8),
           let existing = try? TOMLTable(string: raw) {
            table = existing
        } else {
            table = TOMLTable()
        }

        // Build otel section
        let otel = TOMLTable()
        otel["environment"] = "production"
        otel["log_user_prompt"] = false

        func makeExporter(path: String) -> TOMLTable {
            let exporter = TOMLTable()
            let otlpHttp = TOMLTable()
            otlpHttp["endpoint"] = "\(Self.ingestURL)/v1/\(path)"
            otlpHttp["protocol"] = "json"
            let headers = TOMLTable()
            headers["x-api-key"] = apiKey
            otlpHttp["headers"] = headers
            exporter["otlp-http"] = otlpHttp
            return exporter
        }

        // Log exporter only. Every codex.* product event goes through the log
        // exporter (codex-rs `log_event!` / `log_and_trace_event!`). The trace
        // exporter additionally ships every internal tracing span (receiving,
        // handle_responses, append_items, ...): ~1M rows/day/user of noise that
        // filled the backend database in Sept 2026.
        otel["exporter"] = makeExporter(path: "logs")
        // Codex >= 0.129 already defaults trace_exporter to "none"
        // (codex-rs core/src/config/otel.rs); saying so explicitly also overrides
        // a system or managed config layer and Codex <= 0.128, which fell back
        // to the log exporter.
        otel["trace_exporter"] = "none"
        table["otel"] = otel

        try table.convert().write(to: codexConfigPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexConfigPath.path)
        try writeSourceBackup(sourceType: "codex", apiKey: apiKey)
    }

    /// True when our `[otel]` section does not pin `trace_exporter = "none"`:
    /// either an older LobsterOne wrote `[otel.trace_exporter]` (builds <= 125),
    /// or it predates the explicit "none". Rewriting the config with the current
    /// key fixes both. False when Codex has no `[otel]` section (not ours).
    func codexConfigNeedsTraceExporterOff() -> Bool {
        guard let raw = try? String(contentsOf: codexConfigPath, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let otel = table["otel"]?.table else {
            return false
        }
        return otel["trace_exporter"]?.string != "none"
    }

    func removeCodexConfig() throws {
        guard let raw = try? String(contentsOf: codexConfigPath, encoding: .utf8),
              let table = try? TOMLTable(string: raw) else {
            return
        }
        table.remove(at: "otel")
        try table.convert().write(to: codexConfigPath, atomically: true, encoding: .utf8)
        removeSourceBackup(sourceType: "codex")
    }

    // MARK: - Mistral Vibe

    func isVibeInstalled() -> Bool {
        let vibeDir = homeDirectory.appendingPathComponent(".vibe/sessions")
        if FileManager.default.fileExists(atPath: vibeDir.path) { return true }
        // Check if vibe command is available
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["which", "vibe"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func writeMistralVibeConfig(apiKey: String) throws {
        // Vibe needs no on-disk reconfiguration; persist the key in our own backup store.
        try writeSourceBackup(sourceType: "mistral-vibe", apiKey: apiKey)
    }

    func readMistralVibeAPIKey() -> String? {
        readSourceBackup(sourceType: "mistral-vibe").flatMap { $0.hasPrefix("rc_") ? $0 : nil }
    }

    func isMistralVibeConfigured() -> Bool {
        readMistralVibeAPIKey() != nil
    }

    func removeMistralVibeConfig() {
        removeSourceBackup(sourceType: "mistral-vibe")
    }

    // MARK: - Source enumeration

    struct ConfiguredSource {
        let type: String        // "claude-code", "codex", or "mistral-vibe"
        let displayName: String
        let apiKey: String
        var keyPrefix: String { String(apiKey.prefix(10)) + "..." }
    }

    func configuredSources() -> [ConfiguredSource] {
        var sources: [ConfiguredSource] = []
        if let key = readAPIKeyFromSettings() {
            sources.append(ConfiguredSource(type: "claude-code", displayName: "Claude Code", apiKey: key))
        }
        if let key = readCodexAPIKey() {
            sources.append(ConfiguredSource(type: "codex", displayName: "Codex", apiKey: key))
        }
        if let key = readMistralVibeAPIKey() {
            sources.append(ConfiguredSource(type: "mistral-vibe", displayName: "Mistral Vibe", apiKey: key))
        }
        return sources
    }

    func unconfiguredInstalledSources() -> [ConfiguredSource] {
        var sources: [ConfiguredSource] = []
        if readAPIKeyFromSettings() == nil && isClaudeCodeInstalled() {
            sources.append(ConfiguredSource(type: "claude-code", displayName: "Claude Code", apiKey: ""))
        }
        if readCodexAPIKey() == nil && isCodexInstalled() {
            sources.append(ConfiguredSource(type: "codex", displayName: "Codex", apiKey: ""))
        }
        if readMistralVibeAPIKey() == nil && isVibeInstalled() {
            sources.append(ConfiguredSource(type: "mistral-vibe", displayName: "Mistral Vibe", apiKey: ""))
        }
        return sources
    }

    // MARK: - Claude Code settings.json (private)

    private func readAPIKeyFromSettings() -> String? {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = Self.stringEnv(json)["OTEL_EXPORTER_OTLP_HEADERS"] else {
            return nil
        }
        guard headers.hasPrefix("x-api-key=") else { return nil }
        let key = String(headers.dropFirst("x-api-key=".count))
        guard key.hasPrefix("rc_") else { return nil }
        return key
    }

    private func readAPIKeyFromBackup() -> String? {
        guard let data = try? Data(contentsOf: backupPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Multi-source format
        if let sources = json["sources"] as? [String: Any],
           let claude = sources["claude-code"] as? [String: Any],
           let key = claude["apiKey"] as? String, key.hasPrefix("rc_") {
            return key
        }
        // Legacy single-key format
        if let key = json["apiKey"] as? String, key.hasPrefix("rc_") {
            return key
        }
        return nil
    }

    private func readSourceBackup(sourceType: String) -> String? {
        guard let data = try? Data(contentsOf: backupPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = json["sources"] as? [String: Any],
              let source = sources[sourceType] as? [String: Any],
              let key = source["apiKey"] as? String else {
            return nil
        }
        return key
    }

    private func writeSettingsJSON(apiKey: String) throws {
        var json = try readClaudeSettings() ?? [:]
        // Values stay as they are: env can hold numbers or booleans too.
        var env = json["env"] as? [String: Any] ?? [:]
        for (key, value) in Self.otelKeys {
            env[key] = value
        }
        env["OTEL_EXPORTER_OTLP_HEADERS"] = "x-api-key=\(apiKey)"
        json["env"] = env
        try writeClaudeSettings(json)
    }

    private func removeFromSettingsJSON() throws {
        guard var json = try readClaudeSettings(),
              var env = json["env"] as? [String: Any] else {
            return
        }
        let keysToRemove = Array(Self.otelKeys.keys) + ["OTEL_EXPORTER_OTLP_HEADERS"]
        guard keysToRemove.contains(where: { env[$0] != nil }) else { return }
        for key in keysToRemove {
            env.removeValue(forKey: key)
        }
        json["env"] = env
        try writeClaudeSettings(json)
    }

    /// The parsed settings, nil when there's no file (or only whitespace). Throws rather than
    /// returning something empty when the file is there but isn't JSON, so a write can't
    /// replace the person's settings with ours alone.
    private func readClaudeSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return nil }
        let data = try Data(contentsOf: settingsPath)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.unreadableClaudeSettings
        }
        return json
    }

    /// Atomic write, 0600, after keeping one copy of the file as it was before our first change.
    private func writeClaudeSettings(_ json: [String: Any]) throws {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: settingsPath.path),
           !FileManager.default.fileExists(atPath: settingsBackupPath.path) {
            try FileManager.default.copyItem(at: settingsPath, to: settingsBackupPath)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmpPath = settingsPath.appendingPathExtension("tmp")
        try data.write(to: tmpPath)
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            _ = try FileManager.default.replaceItemAt(settingsPath, withItemAt: tmpPath)
        } else {
            try FileManager.default.moveItem(at: tmpPath, to: settingsPath)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath.path)
    }

    /// The string values of a settings file's env, ignoring any that aren't strings.
    static func stringEnv(_ json: [String: Any]) -> [String: String] {
        (json["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    // MARK: - Multi-source backup

    private func writeSourceBackup(sourceType: String, apiKey: String) throws {
        let lobsteroneDir = homeDirectory.appendingPathComponent(".lobsterone")
        try FileManager.default.createDirectory(at: lobsteroneDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        var sources: [String: Any] = [:]
        if let data = try? Data(contentsOf: backupPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let existing = json["sources"] as? [String: Any] {
                sources = existing
            } else if let oldKey = json["apiKey"] as? String {
                // Migrate legacy single-key format
                sources["claude-code"] = ["apiKey": oldKey, "configuredAt": json["configuredAt"] ?? ""]
            }
        }

        let formatter = ISO8601DateFormatter()
        sources[sourceType] = ["apiKey": apiKey, "configuredAt": formatter.string(from: Date())]

        let backup: [String: Any] = ["sources": sources]
        let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: backupPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath.path)
    }

    private func removeSourceBackup(sourceType: String) {
        guard let data = try? Data(contentsOf: backupPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if var sources = json["sources"] as? [String: Any] {
            sources.removeValue(forKey: sourceType)
            json["sources"] = sources
        } else if sourceType == "claude-code" {
            // Legacy single-key backups only ever held the Claude Code key.
            json.removeValue(forKey: "apiKey")
            json.removeValue(forKey: "configuredAt")
        } else {
            return
        }
        if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: backupPath)
        }
    }

    // MARK: - Diagnostics

    private static let otelShellPatterns = [
        "OTEL_EXPORTER_OTLP",
        "OTEL_METRICS_EXPORTER",
        "OTEL_LOGS_EXPORTER",
        "OTEL_TRACES_EXPORTER",
        "CLAUDE_CODE_ENABLE_TELEMETRY",
    ]

    private var shellProfilePaths: [URL] {
        [".zshrc", ".bashrc", ".zprofile", ".bash_profile"].map {
            homeDirectory.appendingPathComponent($0)
        }
    }

    func scanShellProfiles() -> [String] {
        var affected: [String] = []
        for path in shellProfilePaths {
            guard let content = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let hasOtel = content.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("export ") || (trimmed.contains("=") && !trimmed.hasPrefix("#")) else { return false }
                return Self.otelShellPatterns.contains { trimmed.contains($0) }
            }
            if hasOtel {
                affected.append(path.lastPathComponent)
            }
        }
        return affected
    }

    func removeShellOtelExports(from filename: String) throws {
        let path = homeDirectory.appendingPathComponent(filename)
        var content = try String(contentsOf: path, encoding: .utf8)

        let blockPattern = #"# == START ROBOCOG CONFIG ==[\s\S]*?# == END ROBOCOG CONFIG ==\n?"#
        if let range = content.range(of: blockPattern, options: .regularExpression) {
            content.replaceSubrange(range, with: "# LobsterOne: OTEL exports removed by diagnostics (managed per-tool now)\n")
        } else {
            var lines = content.components(separatedBy: "\n")
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isOtelExport = (trimmed.hasPrefix("export ") || (trimmed.contains("=") && !trimmed.hasPrefix("#")))
                    && Self.otelShellPatterns.contains(where: { trimmed.contains($0) })
                return isOtelExport ? "# LobsterOne: removed — \(line)" : line
            }
            content = lines.joined(separator: "\n")
        }

        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Detects environment-level overrides that can silently block Claude Code
    /// telemetry even when ~/.claude/settings.json is correctly configured.
    /// Process env beats settings.json, settings.local.json beats settings.json,
    /// and managed settings beat everything — none of which the config check sees.
    func scanTelemetryOverrides() -> [String] {
        var findings: [String] = []

        // settings.local.json env overrides settings.json env per-key
        let localSettings = homeDirectory.appendingPathComponent(".claude/settings.local.json")
        if let data = try? Data(contentsOf: localSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["env"] != nil {
            let env = Self.stringEnv(json)
            let conflicts = env.keys.filter { key in
                key == "DISABLE_TELEMETRY" || key == "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
                    || ((key.hasPrefix("OTEL_") || key == "CLAUDE_CODE_ENABLE_TELEMETRY") && env[key] != Self.otelKeys[key])
            }
            if !conflicts.isEmpty {
                findings.append("~/.claude/settings.local.json overrides \(conflicts.sorted().joined(separator: ", "))")
            }
        }

        // Managed (MDM/enterprise) settings take precedence over user settings
        let managedPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
        if FileManager.default.fileExists(atPath: managedPath) {
            findings.append("managed-settings.json present (can override telemetry)")
        }

        // launchctl user environment applies to GUI-launched terminals and
        // survives shell profile scans
        let launchctlVars = [
            "DISABLE_TELEMETRY", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_METRICS_EXPORTER",
            "OTEL_LOGS_EXPORTER", "OTEL_EXPORTER_OTLP_ENDPOINT",
        ]
        for name in launchctlVars {
            if let value = launchctlGetenv(name), value != Self.otelKeys[name] {
                findings.append("launchctl env \(name)=\(value)")
            }
        }

        return findings
    }

    private func launchctlGetenv(_ name: String) -> String? {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["getenv", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    func checkClaudeCodeOtel() -> (configured: Bool, endpoint: String?, keyPrefix: String?) {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["env"] != nil else {
            return (false, nil, nil)
        }
        let env = Self.stringEnv(json)
        let endpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"]
        let headers = env["OTEL_EXPORTER_OTLP_HEADERS"] ?? ""
        let keyMatch = headers.components(separatedBy: "=").last
        let keyPrefix = keyMatch?.hasPrefix("rc_") == true ? String(keyMatch!.prefix(10)) + "..." : nil
        return (endpoint != nil && keyPrefix != nil, endpoint, keyPrefix)
    }

    func checkCodexOtel() -> (configured: Bool, endpoint: String?, keyPrefix: String?) {
        guard let raw = try? String(contentsOf: codexConfigPath, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let otel = table["otel"]?.table,
              let exporter = otel["exporter"]?.table,
              let otlpHttp = exporter["otlp-http"]?.table else {
            return (false, nil, nil)
        }
        let endpoint = otlpHttp["endpoint"]?.string
        let keyPrefix: String?
        if let headers = otlpHttp["headers"]?.table,
           let key = headers["x-api-key"]?.string, key.hasPrefix("rc_") {
            keyPrefix = String(key.prefix(10)) + "..."
        } else {
            keyPrefix = nil
        }
        return (endpoint != nil && keyPrefix != nil, endpoint, keyPrefix)
    }
}
