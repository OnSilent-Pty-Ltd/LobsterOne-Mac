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
                DebugLog.shared.log("Claude credentials file found but token expired (expiresAt=\(creds.expiresAt), sub=\(creds.subscriptionType ?? "nil"))")
                return nil
            }
            cachedCredentials = creds
            DebugLog.shared.log("Claude credentials loaded from file (sub=\(creds.subscriptionType ?? "nil"), tier=\(creds.rateLimitTier ?? "nil"), token=\(String(creds.accessToken.prefix(12)))...)")
            return creds
        }

        // Tier 2: Try keychain via /usr/bin/security CLI (no ACL prompt)
        if let creds = readFromKeychain() {
            if creds.isExpired {
                DebugLog.shared.log("Claude credentials from keychain but token expired (expiresAt=\(creds.expiresAt))")
                return nil
            }
            cachedCredentials = creds
            DebugLog.shared.log("Claude credentials loaded from keychain (sub=\(creds.subscriptionType ?? "nil"), tier=\(creds.rateLimitTier ?? "nil"))")
            return creds
        }

        // Log what we found at each tier for debugging
        let fileExists = FileManager.default.fileExists(atPath: credentialsPath)
        DebugLog.shared.log("No Claude credentials found — file exists: \(fileExists), path: \(credentialsPath)")
        return nil
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
            DebugLog.shared.log("Claude token expired and claude CLI not found — cannot delegate refresh")
            return nil
        }

        DebugLog.shared.log("Claude token expired — running claude -p /usage so the CLI refreshes it")
        let ok = await Self.runClaudeRefresh(claudePath: claudePath)
        guard ok else {
            DebugLog.shared.log("Delegated refresh: claude -p /usage failed or timed out")
            return nil
        }

        invalidateCache()
        let refreshed = readCredentials()
        DebugLog.shared.log(refreshed != nil
            ? "Delegated refresh OK — Claude token valid again"
            : "Delegated refresh ran but token is still expired")
        return refreshed
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

    /// Runs `claude -p /usage` off the main actor with a hard timeout.
    /// No session persistence, so our own session scanner never sees these runs.
    nonisolated private static func runClaudeRefresh(claudePath: String, timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = ["-p", "--no-session-persistence", "/usage"]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
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
