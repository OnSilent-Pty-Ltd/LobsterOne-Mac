import Foundation

/// Reads Claude Code's OAuth credentials from the local filesystem or macOS Keychain.
/// Read-only — never writes to credentials to avoid breaking Claude Code's session.
///
/// Keychain reads use `/usr/bin/security` CLI instead of Security.framework to avoid
/// macOS ACL password prompts (same approach as OpenUsage and CodexBar).
@MainActor
final class ClaudeCredentialService {
    private let credentialsPath: String
    private let keychainService = "Claude Code-credentials"

    /// Cached credentials — re-read from source only when token is near expiry.
    private var cachedCredentials: ClaudeOAuthCredentials?

    /// The expired token we last logged, so a stale token is logged once, not every poll.
    private var lastLoggedExpiredAt: Int64?

    init() {
        let home = NSHomeDirectory()
        self.credentialsPath = (home as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    /// Returns valid (non-expired) OAuth credentials, or nil.
    func readCredentials() -> ClaudeOAuthCredentials? {
        // Serve from cache if token is still valid
        if let cached = cachedCredentials, !cached.isExpiredOrExpiringSoon {
            return cached
        }

        // Tier 1: Try credentials file (fastest, no subprocess)
        if let creds = readFromFile() {
            if creds.isExpired {
                logExpired(creds, source: "credentials file")
                return nil
            }
            cachedCredentials = creds
            DebugLog.shared.log("Claude credentials loaded from file (sub=\(creds.subscriptionType ?? "nil"), tier=\(creds.rateLimitTier ?? "nil"), \(creds.expiryDescription()))")
            return creds
        }

        // Tier 2: Try keychain via /usr/bin/security CLI (no ACL prompt)
        if let creds = readFromKeychain() {
            if creds.isExpired {
                logExpired(creds, source: "Keychain")
                return nil
            }
            cachedCredentials = creds
            DebugLog.shared.log("Claude credentials loaded from Keychain (sub=\(creds.subscriptionType ?? "nil"), tier=\(creds.rateLimitTier ?? "nil"), \(creds.expiryDescription()))")
            return creds
        }

        // Log what we found at each tier for debugging
        let fileExists = FileManager.default.fileExists(atPath: credentialsPath)
        DebugLog.shared.log("No Claude credentials found — file exists: \(fileExists), path: \(credentialsPath)")
        return nil
    }

    private func logExpired(_ creds: ClaudeOAuthCredentials, source: String) {
        guard creds.expiresAt != lastLoggedExpiredAt else { return }
        lastLoggedExpiredAt = creds.expiresAt
        DebugLog.shared.log("Claude token in \(source) \(creds.expiryDescription()) (sub=\(creds.subscriptionType ?? "nil"))")
    }

    /// Invalidate the cache so the next read goes to source.
    func invalidateCache() {
        cachedCredentials = nil
    }

    // MARK: - Delegated Refresh (via claude CLI)

    /// Last delegated-refresh attempt — bounded so we don't spawn claude on every poll.
    private var lastDelegatedRefreshAttempt: Date = .distantPast
    private let delegatedRefreshCooldown: TimeInterval = 10 * 60

    /// Returns valid credentials, delegating a token refresh to the Claude CLI
    /// when the stored token is expired.
    ///
    /// We deliberately never call Anthropic's token endpoint with the CLI's
    /// refresh token: refresh tokens rotate, and consuming the CLI's token from
    /// here would invalidate the user's Claude Code login (same reasoning as
    /// CodexBar's delegated refresh). `claude -p /usage` is a local slash
    /// command (no model call) that makes the CLI refresh and persist its own
    /// token before querying usage; we re-read after. `claude auth status` used
    /// to do this too, but stopped refreshing around CLI 2.1.3xx.
    func readCredentialsRefreshingIfNeeded() async -> ClaudeOAuthCredentials? {
        if let creds = readCredentials() { return creds }

        guard Date().timeIntervalSince(lastDelegatedRefreshAttempt) >= delegatedRefreshCooldown else {
            return nil
        }
        lastDelegatedRefreshAttempt = Date()

        guard let claudePath = Self.resolveClaudeBinary() else {
            DebugLog.shared.log("Delegated refresh failed: claude CLI not found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.claude/local or PATH")
            return nil
        }

        let shownPath = claudePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        DebugLog.shared.log("Delegated refresh: running \(shownPath) -p /usage so the CLI refreshes its token")
        let outcome = await Self.runClaudeRefresh(claudePath: claudePath)
        let retry = "next try in \(Int(delegatedRefreshCooldown / 60)) min"

        if let launchError = outcome.launchError {
            DebugLog.shared.log("Delegated refresh failed: could not start claude (\(launchError)); \(retry)")
            return nil
        }
        let took = String(format: "%.1fs", outcome.duration)
        if outcome.timedOut {
            DebugLog.shared.log("Delegated refresh failed: claude timed out after \(took); \(retry). Output: \(outcome.outputTail)")
            return nil
        }
        guard outcome.exitCode == 0 else {
            DebugLog.shared.log("Delegated refresh failed: claude exited with code \(outcome.exitCode) after \(took); \(retry). Output: \(outcome.outputTail)")
            return nil
        }

        invalidateCache()
        lastLoggedExpiredAt = nil
        if let refreshed = readCredentials() {
            DebugLog.shared.log("Delegated refresh OK in \(took): token \(refreshed.expiryDescription())")
            return refreshed
        }
        DebugLog.shared.log("Delegated refresh ran (exit 0, \(took)) but the stored token is still expired, so the CLI did not write a new one; \(retry). Output: \(outcome.outputTail)")
        return nil
    }

    /// Locates the claude binary. GUI apps don't inherit the user's shell PATH,
    /// so check common install locations before falling back to a PATH lookup.
    nonisolated static func resolveClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
        } catch {
            return nil
        }
        which.waitUntilExit()
        guard which.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    struct RefreshOutcome {
        var exitCode: Int32 = -1
        var timedOut = false
        var duration: TimeInterval = 0
        var launchError: String?
        /// Last few hundred characters of stdout and stderr, on one line.
        var outputTail = ""
    }

    /// Runs `claude -p /usage` off the main actor with a hard timeout.
    /// No session persistence, so our own session scanner never sees these runs.
    /// Output goes to a temp file rather than a pipe: claude can start child
    /// processes (MCP servers) that inherit the pipe and keep it open after exit.
    nonisolated static func runClaudeRefresh(claudePath: String, arguments: [String] = ["-p", "--no-session-persistence", "/usage"], timeout: TimeInterval = 30) async -> RefreshOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var outcome = RefreshOutcome()
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lobsterone-claude-refresh-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: outputURL) }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let output = try? FileHandle(forWritingTo: outputURL)
                process.standardOutput = output ?? FileHandle.nullDevice
                process.standardError = output ?? FileHandle.nullDevice

                let started = Date()
                do {
                    try process.run()
                } catch {
                    outcome.launchError = error.localizedDescription
                    try? output?.close()
                    continuation.resume(returning: outcome)
                    return
                }
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                try? output?.close()

                outcome.duration = Date().timeIntervalSince(started)
                // Our terminate() sends SIGTERM; a signal exit at the deadline is the timeout.
                outcome.timedOut = process.terminationReason == .uncaughtSignal && outcome.duration >= timeout - 0.5
                outcome.exitCode = process.terminationStatus
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                outcome.outputTail = tail(of: data)
                continuation.resume(returning: outcome)
            }
        }
    }

    /// The end of the command's output, newlines folded, capped so one line stays readable.
    nonisolated static func tail(of data: Data, limit: Int = 400) -> String {
        let text = String(decoding: data.suffix(limit * 4), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        if text.isEmpty { return "(none)" }
        return text.count > limit ? "…" + String(text.suffix(limit)) : text
    }

    // MARK: - File Reader

    private func readFromFile() -> ClaudeOAuthCredentials? {
        guard FileManager.default.fileExists(atPath: credentialsPath),
              let data = FileManager.default.contents(atPath: credentialsPath) else {
            return nil
        }
        return parseCredentials(from: data)
    }

    // MARK: - Keychain Reader (via /usr/bin/security CLI)

    private func readFromKeychain() -> ClaudeOAuthCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            DebugLog.shared.log("security CLI failed to launch: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        // Try parsing the raw output (may have trailing newline)
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let trimmedData = str.data(using: .utf8),
           let creds = parseCredentials(from: trimmedData) {
            return creds
        }

        // Try hex decoding (macOS security CLI hex-encodes values with newlines)
        if let decoded = hexDecode(data), let creds = parseCredentials(from: decoded) {
            return creds
        }

        DebugLog.shared.log("Keychain data found but could not parse credentials")
        return nil
    }

    // MARK: - JSON Parsing

    private func parseCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        do {
            let file = try JSONDecoder().decode(ClaudeCredentialsFile.self, from: data)
            guard let oauth = file.claudeAiOauth, !oauth.accessToken.isEmpty else {
                // Log what keys are present to diagnose team/business account differences
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ", ")
                    DebugLog.shared.log("Credentials file parsed but no claudeAiOauth — top-level keys: [\(keys)]")
                    if let oauth = json["claudeAiOauth"] as? [String: Any] {
                        let oauthKeys = oauth.keys.sorted().joined(separator: ", ")
                        DebugLog.shared.log("claudeAiOauth present but empty/invalid — keys: [\(oauthKeys)]")
                    }
                }
                return nil
            }
            return oauth
        } catch {
            // Log the raw JSON keys for debugging different account types
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = json.keys.sorted().joined(separator: ", ")
                DebugLog.shared.log("Credentials parse failed — top-level keys: [\(keys)], error: \(error)")
            } else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
                DebugLog.shared.log("Credentials parse failed — not valid JSON, preview: \(preview), error: \(error)")
            }
            return nil
        }
    }

    // MARK: - Hex Decoding

    /// Decodes hex-encoded UTF-8 bytes. macOS Keychain sometimes returns values this way.
    private func hexDecode(_ data: Data) -> Data? {
        guard let hexString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }

        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }

        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard hex.unicodeScalars.allSatisfy({ hexChars.contains($0) }) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }

        return Data(bytes)
    }
}
