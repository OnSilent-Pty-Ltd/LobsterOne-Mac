import Foundation

/// Adds the LobsterOne mod to Claude Code, keeps it in step with app updates, and takes it out.
///
/// The mod is the band above Claude Code's prompt: the project's name and logo, a live trace,
/// the crew at work, the session in the project's colours. Release builds carry it in
/// `Contents/Library/ClaudeCode/lobsterone`. Adding copies it to Application Support, with the
/// crew portraits beside it, then has Claude Code read it from there as a plugin, through the
/// `claude plugin` commands, so Claude Code's own records stay the truth: what Settings shows is
/// what `claude plugin list` says. An app update copies newer files over that folder; Claude Code
/// reads a folder plugin live, so open sessions pick them up with `/reload-plugins`.
struct ClaudeCodeMod: Sendable {
    static let pluginID = "lobsterone@lobsterone"
    static let marketplaceName = "lobsterone"

    enum State: Equatable, Sendable {
        /// There's no `claude` on this Mac.
        case claudeMissing
        /// This build doesn't carry the mod, and Claude Code doesn't have it.
        case notBundled
        case notInstalled
        case installed(version: String?)
        /// Installed, but turned off in Claude Code (its `/plugin` menu). Left alone until the
        /// person turns it back on from Settings.
        case switchedOff(version: String?)
    }

    enum Failure: LocalizedError, Equatable {
        case claudeMissing
        case notBundled
        /// Claude Code refused, in its own words.
        case claudeSaid(String)

        var errorDescription: String? {
            switch self {
            case .claudeMissing: "Claude Code isn't on this Mac."
            case .notBundled: "This build of LobsterOne doesn't include the Claude Code band."
            case .claudeSaid(let words): "Claude Code said: \(words)"
            }
        }
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `claude` with these arguments; nil when there's no `claude` to run.
    typealias Claude = @Sendable ([String]) async -> Output

    let bundledURL: URL?
    let installedURL: URL
    /// The crew portraits to copy beside the mod, which reads them from there.
    let portraits: [URL]
    let claude: Claude?

    // MARK: - Where things are

    /// The copy this app carries. A debug build on a developer's Mac uses the repo's folder.
    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/ClaudeCode/lobsterone")
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".claude-plugin/plugin.json").path) {
            return url
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ClaudeCodeMod")
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent(".claude-plugin/plugin.json").path) {
            return repo
        }
        #endif
        return nil
    }

    static let installedURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LobsterOne/ClaudeCode/lobsterone")

    static var portraitURLs: [URL] {
        #if SWIFT_PACKAGE
        return Bundle.module.urls(forResourcesWithExtension: "jpg", subdirectory: "Crew") ?? []
        #else
        // The Xcode project flattens resources into Contents/Resources.
        return (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("crew-") }
        #endif
    }

    /// The real thing: this app's copy, Application Support, and the `claude` on this Mac.
    static func live() -> ClaudeCodeMod {
        let path = ClaudeCredentialService.resolveClaudeBinary()
        return ClaudeCodeMod(bundledURL: bundledURL,
                             installedURL: installedURL,
                             portraits: portraitURLs,
                             claude: path.map { path in { arguments in await run(path, arguments) } })
    }

    /// The files alone, for an update at launch: no need to look for `claude`.
    static func filesOnly() -> ClaudeCodeMod {
        ClaudeCodeMod(bundledURL: bundledURL, installedURL: installedURL, portraits: portraitURLs, claude: nil)
    }

    // MARK: - State

    /// What Claude Code says about the mod now.
    func state() async -> State {
        guard let claude else { return .claudeMissing }
        let listed = await claude(["plugin", "list", "--json"])
        let entry = Self.entry(in: listed.stdout)
        guard let entry else { return bundledURL == nil ? .notBundled : .notInstalled }
        let version = (entry["folderVersion"] as? String) ?? (entry["version"] as? String)
        return (entry["enabled"] as? Bool ?? true) ? .installed(version: version) : .switchedOff(version: version)
    }

    /// The mod's row in `claude plugin list --json`, or nil when it isn't installed or the
    /// output can't be read.
    static func entry(in json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.first { ($0["id"] as? String) == pluginID }
    }

    // MARK: - Adding, turning on, removing

    /// Copies the mod into place and has Claude Code install it. Safe to run again: an existing
    /// marketplace or install is taken as done, and a switched-off mod is turned back on.
    func install() async throws {
        guard let claude else { throw Failure.claudeMissing }
        guard bundledURL != nil else { throw Failure.notBundled }
        try copyFiles()

        let added = await claude(["plugin", "marketplace", "add", installedURL.path, "--json"])
        if added.status != 0, !Self.saysAlready(added) {
            throw Failure.claudeSaid(Self.words(added))
        }
        let installed = await claude(["plugin", "install", Self.pluginID, "--scope", "user", "--yes", "--json"])
        if installed.status != 0, !Self.saysAlready(installed) {
            throw Failure.claudeSaid(Self.words(installed))
        }
        if case .switchedOff = await state() {
            try await turnOn()
        }
    }

    /// Turns the mod back on after it was switched off in Claude Code.
    func turnOn() async throws {
        guard let claude else { throw Failure.claudeMissing }
        let enabled = await claude(["plugin", "enable", Self.pluginID, "--json"])
        if enabled.status != 0, !Self.saysAlready(enabled) {
            throw Failure.claudeSaid(Self.words(enabled))
        }
    }

    /// Uninstalls the mod, forgets its marketplace and deletes the copied files. Each step runs
    /// even when an earlier one finds nothing to undo.
    func remove() async throws {
        if let claude {
            let uninstalled = await claude(["plugin", "uninstall", Self.pluginID, "--json"])
            _ = await claude(["plugin", "marketplace", "remove", Self.marketplaceName, "--json"])
            if uninstalled.status != 0, case .installed = await state() {
                throw Failure.claudeSaid(Self.words(uninstalled))
            }
        }
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try FileManager.default.removeItem(at: installedURL)
        }
    }

    // MARK: - Keeping up with the app

    /// After an app update: puts this build's mod over an older copy, if the mod was added.
    /// True when files were replaced.
    @discardableResult
    func refreshFiles() throws -> Bool {
        guard let bundledURL, FileManager.default.fileExists(atPath: installedURL.path),
              let bundled = Self.version(at: bundledURL),
              Self.isNewer(bundled, than: Self.version(at: installedURL)) else { return false }
        try copyFiles()
        return true
    }

    /// The `version` in a mod folder's plugin.json.
    static func version(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    /// Dotted versions compared part by part: "0.10.0" is newer than "0.9.4".
    static func isNewer(_ candidate: String, than installed: String?) -> Bool {
        guard let installed else { return true }
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Copies the bundled mod and the portraits beside it, staged first so a failed copy never
    /// leaves a half-written mod for Claude Code to load.
    private func copyFiles() throws {
        guard let bundledURL else { throw Failure.notBundled }
        let fm = FileManager.default
        let folder = installedURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let staging = folder.appendingPathComponent(".lobsterone-\(UUID().uuidString)")
        try fm.copyItem(at: bundledURL, to: staging)
        do {
            // The repo's test files and editor settings aren't needed where the mod runs.
            for extra in ["tests", "tsconfig.json"] {
                let url = staging.appendingPathComponent(extra)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
            let faces = staging.appendingPathComponent("portraits")
            try fm.createDirectory(at: faces, withIntermediateDirectories: true)
            for portrait in portraits {
                try fm.copyItem(at: portrait, to: faces.appendingPathComponent(portrait.lastPathComponent))
            }
            if fm.fileExists(atPath: installedURL.path) {
                _ = try fm.replaceItemAt(installedURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installedURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Talking to claude

    /// "already" in Claude Code's words: an add or install that has nothing to do.
    static func saysAlready(_ output: Output) -> Bool {
        (output.stdout + output.stderr).range(of: "already", options: .caseInsensitive) != nil
    }

    /// Claude Code's reason, as one line for the person: the JSON line's `error` when there is
    /// one, else the first line of what it printed.
    static func words(_ output: Output) -> String {
        for line in output.stdout.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = (object["error"] as? String) ?? (object["message"] as? String), !error.isEmpty {
                return String(error.prefix(240))
            }
        }
        let text = output.stderr.isEmpty ? output.stdout : output.stderr
        let first = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "it stopped with code \(output.status)." : String(first.prefix(240))
    }

    /// Runs `claude` off the main thread with a time limit. An app opened from the Finder has a
    /// bare PATH, so the usual install folders go on it for a claude that's a Node script.
    static func run(_ claude: String, _ arguments: [String], timeout: TimeInterval = 120) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claude)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
                    .joined(separator: ":")
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      stdout: String(decoding: stdout, as: UTF8.self),
                                                      stderr: String(decoding: stderr, as: UTF8.self)))
            }
        }
    }
}
