import Foundation

/// Which AWS login the user picked. This is what gets persisted, so it holds
/// no secrets: a profile name, or a marker that the keys are in the Keychain.
nonisolated enum AWSConnection: Codable, Equatable, Hashable, Sendable {
    case profile(name: String)
    case accessKeys
}

/// Turns an `AWSConnection` into keys. Static keys come straight from the
/// files or the Keychain; every other profile kind (SSO, assumed role,
/// credential_process, MFA) goes through the installed AWS CLI, which already
/// knows how to refresh them. Temporary keys are cached until shortly before
/// they expire, so a refresh doesn't spawn the CLI each time.
actor AWSCredentialProvider {
    /// Renew this long before AWS says the keys expire, so a request signed
    /// just before the cutoff doesn't land just after it.
    static let refreshMargin: TimeInterval = 5 * 60
    static let cliTimeout: TimeInterval = 15

    private let home: URL
    private let runner: any AWSProcessRunning
    private let secrets: any AWSSecretStoring
    private let locateCLI: @Sendable () async -> String?
    private let now: @Sendable () -> Date

    private var cache: [AWSConnection: AWSCredentials] = [:]
    private var inFlight: [AWSConnection: Task<AWSCredentials, Error>] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         runner: any AWSProcessRunning = AWSProcessRunner(),
         secrets: any AWSSecretStoring = AWSKeychainSecrets(),
         locateCLI: (@Sendable () async -> String?)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.runner = runner
        self.secrets = secrets
        self.locateCLI = locateCLI ?? { await AWSCLI.locate(runner: runner) }
        self.now = now
    }

    func credentials(for connection: AWSConnection) async throws -> AWSCredentials {
        if let cached = cache[connection], let expiry = cached.expiration,
           expiry.timeIntervalSince(now()) > Self.refreshMargin {
            return cached
        }
        // Two refreshes at once share one CLI run instead of racing.
        if let running = inFlight[connection] { return try await running.value }

        let task = Task { try await self.resolve(connection) }
        inFlight[connection] = task
        defer { inFlight[connection] = nil }

        let fresh = try await task.value
        cache[connection] = fresh.expiration == nil ? nil : fresh
        return fresh
    }

    /// Drops cached keys, e.g. after AWS rejected them or the user switched login.
    func invalidate(_ connection: AWSConnection? = nil) {
        if let connection { cache[connection] = nil } else { cache.removeAll() }
    }

    private func resolve(_ connection: AWSConnection) async throws -> AWSCredentials {
        switch connection {
        case .accessKeys:
            guard let keys = secrets.readAccessKeys() else { throw AWSClientError.notConnected }
            return AWSCredentials(accessKeyId: keys.id, secretAccessKey: keys.secret)

        case .profile(let name):
            guard AWSProfiles.isValidName(name) else { throw AWSClientError.invalidProfileName(name) }
            switch AWSProfiles.profileKindFromDisk(name, home: home) {
            case .staticKeys:
                guard let keys = AWSProfiles.staticKeysFromDisk(name, home: home) else {
                    throw AWSClientError.notConnected
                }
                return keys
            case .empty:
                throw AWSClientError.notConnected
            case .sso, .needsMFA, .assumeRole, .process:
                return try await exportFromCLI(profile: name)
            }
        }
    }

    private func exportFromCLI(profile: String) async throws -> AWSCredentials {
        guard let aws = await locateCLI() else { throw AWSClientError.cliMissing }
        let result: AWSProcessResult
        do {
            // The name is one argv element, never part of a shell string.
            result = try await runner.run(
                executable: aws,
                arguments: ["configure", "export-credentials", "--profile", profile, "--format", "process"],
                environment: AWSCLI.environment(),
                timeout: Self.cliTimeout)
        } catch {
            throw AWSClientError.cliMissing
        }
        return try AWSCLI.parseExport(result, profile: profile)
    }
}

// MARK: - The AWS CLI

nonisolated enum AWSCLI {
    /// Where Homebrew (Apple silicon, then Intel) and the official installer put it.
    static let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]

    /// GUI apps don't inherit the user's shell PATH, so check the usual places
    /// first, then ask a login shell. The shell command is a constant; no
    /// user input goes into it.
    static func locate(runner: any AWSProcessRunning,
                       isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       shell: String? = ProcessInfo.processInfo.environment["SHELL"]) async -> String? {
        if let found = candidates.first(where: isExecutable) { return found }
        let shellPath = shell.flatMap { $0.hasPrefix("/") && isExecutable($0) ? $0 : nil } ?? "/bin/zsh"
        guard let result = try? await runner.run(executable: shellPath, arguments: ["-l", "-c", "command -v aws"],
                                                 environment: nil, timeout: 5),
              result.exitCode == 0, !result.timedOut else { return nil }
        // Startup files can print banners; the answer is the last absolute path.
        let lines = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let last = lines.last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              last.hasPrefix("/"), isExecutable(last) else { return nil }
        return last
    }

    /// The app's environment, minus anything that could make the CLI use other
    /// keys than the profile's or stop to ask the user something.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_DEFAULT_PROFILE"] {
            env[key] = nil
        }
        env["AWS_PAGER"] = ""
        env["AWS_CLI_AUTO_PROMPT"] = "off"
        env["AWS_EC2_METADATA_DISABLED"] = "true"
        return env
    }

    /// Reads `aws configure export-credentials --format process` output.
    /// stdout holds the keys, so it never reaches an error message.
    static func parseExport(_ result: AWSProcessResult, profile: String) throws -> AWSCredentials {
        if result.timedOut {
            throw AWSClientError.cliFailed(message: "The AWS CLI didn't answer within \(Int(AWSCredentialProvider.cliTimeout)) seconds.")
        }
        guard result.exitCode == 0 else {
            throw classify(stderr: result.stderr, profile: profile)
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let id = json["AccessKeyId"] as? String, !id.isEmpty,
              let secret = json["SecretAccessKey"] as? String, !secret.isEmpty else {
            throw AWSClientError.cliFailed(message: "The AWS CLI returned credentials in a form LobsterOne can't read.")
        }
        let token = (json["SessionToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiry = (json["Expiration"] as? String).flatMap(parseDate)
        return AWSCredentials(accessKeyId: id, secretAccessKey: secret, sessionToken: token, expiration: expiry)
    }

    /// Sorts a failed export by what the user has to do about it.
    static func classify(stderr: String, profile: String) -> AWSClientError {
        let text = stderr.lowercased()
        if text.contains("could not be found") && text.contains("profile") {
            return .notConnected
        }
        // aws-cli v1, and v2 before 2.9, have no `configure export-credentials`.
        if text.contains("invalid choice") {
            return .cliFailed(message: "This AWS CLI is too old. LobsterOne needs version 2.9 or later.")
        }
        let signInHints = ["sso login", "token has expired", "unable to locate credentials", "sso token",
                           "sso session", "expired", "refresh failed", "mfa"]
        if signInHints.contains(where: text.contains) {
            return .needsSignIn(profile: profile)
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .cliFailed(message: trimmed.isEmpty ? "The AWS CLI failed without saying why." : String(trimmed.prefix(300)))
    }

    /// The CLI writes e.g. `2026-11-18T12:00:00+00:00`, sometimes with fractions.
    static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}

// MARK: - Running processes

nonisolated struct AWSProcessResult: Sendable, CustomStringConvertible {
    let exitCode: Int32
    /// Holds secrets for `export-credentials`. Kept as bytes and left out of `description`.
    let stdout: Data
    let stderr: String
    let timedOut: Bool

    var description: String {
        "AWSProcessResult(exit \(exitCode), \(stdout.count) bytes stdout, timedOut \(timedOut))"
    }
}

nonisolated protocol AWSProcessRunning: Sendable {
    /// Throws only when the executable can't be started.
    func run(executable: String, arguments: [String], environment: [String: String]?,
             timeout: TimeInterval) async throws -> AWSProcessResult
}

/// Runs a process off the main actor with no stdin (so nothing can wait on a
/// prompt) and a hard timeout: SIGTERM, then SIGKILL two seconds later.
nonisolated struct AWSProcessRunner: AWSProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String]?,
             timeout: TimeInterval) async throws -> AWSProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let state = RunState()
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    state.markTimedOut()
                    process.terminate()
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Drain both pipes at once; a full pipe would otherwise stall the child.
                let stderrDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    state.setStderr(err.fileHandleForReading.readDataToEndOfFile())
                    stderrDone.signal()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stderrDone.wait()
                killer.cancel()

                continuation.resume(returning: AWSProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: String(decoding: state.stderr, as: UTF8.self),
                    timedOut: state.timedOut))
            }
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false
        private var _stderr = Data()
        var timedOut: Bool { lock.withLock { _timedOut } }
        var stderr: Data { lock.withLock { _stderr } }
        func markTimedOut() { lock.withLock { _timedOut = true } }
        func setStderr(_ data: Data) { lock.withLock { _stderr = data } }
    }
}
