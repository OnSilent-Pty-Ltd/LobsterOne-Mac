import Testing
import Foundation
@testable import LobsterOne

/// Hands back canned CLI results and records what it was asked to run.
private final class FakeRunner: AWSProcessRunning, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let environment: [String: String]?; let timeout: TimeInterval }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private let respond: @Sendable (Call) throws -> AWSProcessResult

    init(_ respond: @escaping @Sendable (Call) throws -> AWSProcessResult) { self.respond = respond }

    var calls: [Call] { lock.withLock { _calls } }

    func run(executable: String, arguments: [String], environment: [String: String]?,
             timeout: TimeInterval) async throws -> AWSProcessResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        lock.withLock { _calls.append(call) }
        return try respond(call)
    }
}

private final class FakeSecrets: AWSSecretStoring, @unchecked Sendable {
    var keys: (id: String, secret: String)?
    init(_ keys: (id: String, secret: String)?) { self.keys = keys }
    func readAccessKeys() -> (id: String, secret: String)? { keys }
    func saveAccessKeys(id: String, secret: String) throws { keys = (id, secret) }
    func deleteAccessKeys() throws { keys = nil }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now += s } }
}

private let ssoConfig = """
[profile sso-user]
sso_session = main
sso_account_id = 111111111111

[profile admin]
role_arn = arn:aws:iam::111111111111:role/Admin
source_profile = base

[profile region-only]
region = eu-west-1
"""

private let ssoCreds = """
[base]
aws_access_key_id = AKIABASE
aws_secret_access_key = base-secret
"""

private let t0 = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!

private func exportJSON(expiration: String = "2026-11-18T13:00:00+00:00") -> Data {
    Data("""
    {"Version": 1, "AccessKeyId": "ASIAEXPORTED", "SecretAccessKey": "exported-secret",
     "SessionToken": "exported-token", "Expiration": "\(expiration)"}
    """.utf8)
}

private func ok(_ stdout: Data) -> AWSProcessResult {
    AWSProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
}

private func failed(_ stderr: String, exit: Int32 = 255) -> AWSProcessResult {
    AWSProcessResult(exitCode: exit, stdout: Data(), stderr: stderr, timedOut: false)
}

private func provider(runner: FakeRunner, secrets: FakeSecrets = FakeSecrets(nil), cli: String? = "/opt/homebrew/bin/aws",
                      clock: Clock = Clock(t0)) throws -> (AWSCredentialProvider, URL) {
    let home = try makeAWSHome(config: ssoConfig, credentials: ssoCreds)
    let p = AWSCredentialProvider(home: home, runner: runner, secrets: secrets,
                                  locateCLI: { cli }, now: { clock.now })
    return (p, home)
}

// MARK: - Static keys and the Keychain

@Test func providerReadsStaticKeysWithoutTheCLI() async throws {
    let runner = FakeRunner { _ in Issue.record("CLI should not run"); return ok(Data()) }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }
    let keys = try await p.credentials(for: .profile(name: "base"))
    #expect(keys.accessKeyId == "AKIABASE")
    #expect(keys.secretAccessKey == "base-secret")
    #expect(runner.calls.isEmpty)
}

@Test func providerReadsAccessKeysFromSecretStore() async throws {
    let (p, home) = try provider(runner: FakeRunner { _ in ok(Data()) }, secrets: FakeSecrets(("AKIAPASTED", "pasted")))
    defer { try? FileManager.default.removeItem(at: home) }
    let keys = try await p.credentials(for: .accessKeys)
    #expect(keys == AWSCredentials(accessKeyId: "AKIAPASTED", secretAccessKey: "pasted"))
}

@Test func providerWithoutSavedKeysIsNotConnected() async throws {
    let (p, home) = try provider(runner: FakeRunner { _ in ok(Data()) })
    defer { try? FileManager.default.removeItem(at: home) }
    await #expect(throws: AWSClientError.notConnected) { try await p.credentials(for: .accessKeys) }
    await #expect(throws: AWSClientError.notConnected) { try await p.credentials(for: .profile(name: "region-only")) }
    await #expect(throws: AWSClientError.notConnected) { try await p.credentials(for: .profile(name: "nobody")) }
}

@Test func providerRejectsUnsafeProfileNames() async throws {
    let runner = FakeRunner { _ in ok(exportJSON()) }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }
    await #expect(throws: AWSClientError.invalidProfileName("--debug")) {
        try await p.credentials(for: .profile(name: "--debug"))
    }
    #expect(runner.calls.isEmpty)
}

// MARK: - The CLI

@Test func providerExportsSSOProfileThroughCLI() async throws {
    let runner = FakeRunner { _ in ok(exportJSON()) }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }

    let keys = try await p.credentials(for: .profile(name: "sso-user"))
    #expect(keys.accessKeyId == "ASIAEXPORTED")
    #expect(keys.secretAccessKey == "exported-secret")
    #expect(keys.sessionToken == "exported-token")
    #expect(keys.expiration == ISO8601DateFormatter().date(from: "2026-11-18T13:00:00Z"))

    let call = try #require(runner.calls.first)
    #expect(call.executable == "/opt/homebrew/bin/aws")
    #expect(call.arguments == ["configure", "export-credentials", "--profile", "sso-user", "--format", "process"])
    #expect(call.timeout == 15)
    #expect(call.environment?["AWS_CLI_AUTO_PROMPT"] == "off")
}

@Test func providerUsesCLIForAssumedRoles() async throws {
    let runner = FakeRunner { _ in ok(exportJSON()) }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try await p.credentials(for: .profile(name: "admin"))
    #expect(runner.calls.count == 1)
}

@Test func providerCachesTemporaryKeysUntilNearExpiry() async throws {
    let runner = FakeRunner { _ in ok(exportJSON()) }   // expires 13:00
    let clock = Clock(t0)                                // 12:00
    let (p, home) = try provider(runner: runner, clock: clock)
    defer { try? FileManager.default.removeItem(at: home) }

    _ = try await p.credentials(for: .profile(name: "sso-user"))
    clock.advance(50 * 60)                               // 12:50, 10 min left
    _ = try await p.credentials(for: .profile(name: "sso-user"))
    #expect(runner.calls.count == 1)

    clock.advance(6 * 60)                                // 12:56, inside the 5 min margin
    _ = try await p.credentials(for: .profile(name: "sso-user"))
    #expect(runner.calls.count == 2)

    await p.invalidate(.profile(name: "sso-user"))
    _ = try await p.credentials(for: .profile(name: "sso-user"))
    #expect(runner.calls.count == 3)
}

@Test func providerExpiredSSOMeansSignIn() async throws {
    let runner = FakeRunner { _ in
        failed("Error when retrieving token from sso: Token has expired and refresh failed\n")
    }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }
    await #expect(throws: AWSClientError.needsSignIn(profile: "sso-user")) {
        try await p.credentials(for: .profile(name: "sso-user"))
    }
}

@Test func providerMissingCLI() async throws {
    let (p, home) = try provider(runner: FakeRunner { _ in ok(exportJSON()) }, cli: nil)
    defer { try? FileManager.default.removeItem(at: home) }
    await #expect(throws: AWSClientError.cliMissing) { try await p.credentials(for: .profile(name: "sso-user")) }

    // Found on disk but fails to launch (deleted since, not executable).
    let (p2, home2) = try provider(runner: FakeRunner { _ in throw CocoaError(.fileNoSuchFile) })
    defer { try? FileManager.default.removeItem(at: home2) }
    await #expect(throws: AWSClientError.cliMissing) { try await p2.credentials(for: .profile(name: "sso-user")) }
}

@Test func providerGarbageJSONNeverEchoesStdout() async throws {
    let runner = FakeRunner { _ in ok(Data("SECRET-LOOKING-garbage {".utf8)) }
    let (p, home) = try provider(runner: runner)
    defer { try? FileManager.default.removeItem(at: home) }
    do {
        _ = try await p.credentials(for: .profile(name: "sso-user"))
        Issue.record("expected an error")
    } catch let error as AWSClientError {
        guard case .cliFailed(let message) = error else { Issue.record("got \(error)"); return }
        #expect(!message.contains("SECRET"))
    }
}

@Test func cliClassifiesStderr() {
    func c(_ s: String) -> AWSClientError { AWSCLI.classify(stderr: s, profile: "p") }
    #expect(c("Unable to locate credentials. You can configure credentials by running \"aws configure\".") == .needsSignIn(profile: "p"))
    #expect(c("The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.") == .needsSignIn(profile: "p"))
    #expect(c("Error loading SSO Token: Token for main does not exist") == .needsSignIn(profile: "p"))
    #expect(c("An error occurred (ExpiredToken) when calling the AssumeRole operation") == .needsSignIn(profile: "p"))
    #expect(c("Enter MFA code for arn:aws:iam::1:mfa/me: \nEOFError") == .needsSignIn(profile: "p"))
    #expect(c("The config profile (p) could not be found") == .notConnected)
    if case .cliFailed(let m) = c("aws: error: argument operation: Invalid choice, valid choices are:") {
        #expect(m.contains("2.9"))
    } else { Issue.record("old CLI not recognised") }
    if case .cliFailed(let m) = c(String(repeating: "x", count: 1000)) {
        #expect(m.count == 300)
    } else { Issue.record("expected cliFailed") }
}

@Test func cliTimeoutIsReported() {
    let result = AWSProcessResult(exitCode: 15, stdout: Data(), stderr: "", timedOut: true)
    #expect(throws: AWSClientError.cliFailed(message: "The AWS CLI didn't answer within 15 seconds.")) {
        try AWSCLI.parseExport(result, profile: "p")
    }
}

@Test func cliExportWithoutExpirationOrToken() throws {
    let keys = try AWSCLI.parseExport(ok(Data(#"{"Version":1,"AccessKeyId":"AKIA1","SecretAccessKey":"s"}"#.utf8)), profile: "p")
    #expect(keys.sessionToken == nil)
    #expect(keys.expiration == nil)
    #expect(AWSCLI.parseDate("2026-11-18T13:00:00.123Z") != nil)
}

@Test func cliEnvironmentDropsAmbientKeys() {
    let env = AWSCLI.environment(base: ["PATH": "/usr/bin", "AWS_ACCESS_KEY_ID": "x", "AWS_PROFILE": "other"])
    #expect(env["PATH"] == "/usr/bin")
    #expect(env["AWS_ACCESS_KEY_ID"] == nil)
    #expect(env["AWS_PROFILE"] == nil)
    #expect(env["AWS_PAGER"] == "")
}

@Test func cliLocatePrefersKnownPaths() async {
    let runner = FakeRunner { _ in Issue.record("shell should not run"); return ok(Data()) }
    let found = await AWSCLI.locate(runner: runner, isExecutable: { $0 == "/usr/local/bin/aws" }, shell: "/bin/zsh")
    #expect(found == "/usr/local/bin/aws")
}

@Test func cliLocateFallsBackToLoginShell() async {
    let runner = FakeRunner { _ in ok(Data("Welcome banner\n/Users/me/.local/bin/aws\n".utf8)) }
    let found = await AWSCLI.locate(runner: runner, isExecutable: { $0 == "/bin/zsh" || $0 == "/Users/me/.local/bin/aws" },
                                    shell: "/bin/zsh")
    #expect(found == "/Users/me/.local/bin/aws")
    #expect(runner.calls.first?.arguments == ["-l", "-c", "command -v aws"])

    let none = FakeRunner { _ in failed("", exit: 1) }
    #expect(await AWSCLI.locate(runner: none, isExecutable: { $0 == "/bin/zsh" }, shell: "/bin/zsh") == nil)
}

@Test func processRunnerRunsAndTimesOut() async throws {
    let runner = AWSProcessRunner()
    let echo = try await runner.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3"],
                                    environment: nil, timeout: 5)
    #expect(echo.exitCode == 3)
    #expect(String(decoding: echo.stdout, as: UTF8.self) == "out")
    #expect(echo.stderr == "err")
    #expect(!echo.timedOut)

    let slow = try await runner.run(executable: "/bin/sleep", arguments: ["10"], environment: nil, timeout: 0.5)
    #expect(slow.timedOut)

    await #expect(throws: (any Error).self) {
        try await runner.run(executable: "/no/such/aws", arguments: [], environment: nil, timeout: 1)
    }
}

// MARK: - Secrets never print

@Test func credentialsDescriptionRedacts() {
    let keys = AWSCredentials(accessKeyId: "ASIAVERYSECRETID", secretAccessKey: "topsecret", sessionToken: "tok123")
    for text in ["\(keys)", String(describing: keys), String(reflecting: keys), { var s = ""; dump(keys, to: &s); return s }()] {
        #expect(!text.contains("VERYSECRETID"))
        #expect(!text.contains("topsecret"))
        #expect(!text.contains("tok123"))
    }
    #expect("\(keys)".hasPrefix("AWSCredentials(ASIA"))
}

@Test func processResultDescriptionHidesStdout() {
    let r = AWSProcessResult(exitCode: 0, stdout: Data("secret".utf8), stderr: "", timedOut: false)
    #expect(!"\(r)".contains("secret"))
}

@Test func connectionRoundTripsWithoutSecrets() throws {
    for c in [AWSConnection.profile(name: "org-admin"), .accessKeys] {
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(AWSConnection.self, from: data) == c)
    }
}

// MARK: - Real Keychain, unique service per test

@Test func keychainSecretsSaveReadDelete() throws {
    let store = AWSKeychainSecrets(service: "com.lobsterone.mac.test.\(UUID().uuidString)")
    defer { try? store.deleteAccessKeys() }
    #expect(store.readAccessKeys() == nil)
    try store.saveAccessKeys(id: "AKIATEST", secret: "s3cret")
    let read = try #require(store.readAccessKeys())
    #expect(read.id == "AKIATEST")
    #expect(read.secret == "s3cret")
    try store.saveAccessKeys(id: "AKIANEW", secret: "newer")
    #expect(store.readAccessKeys()?.id == "AKIANEW")
    try store.deleteAccessKeys()
    #expect(store.readAccessKeys() == nil)
}

@Test func keychainSecretsUseAppServiceByDefault() {
    #expect(AWSKeychainSecrets().service == "com.lobsterone.mac")
    #expect(AWSKeychainSecrets.idAccount == "aws-access-key-id")
    #expect(AWSKeychainSecrets.secretAccount == "aws-secret-access-key")
}
