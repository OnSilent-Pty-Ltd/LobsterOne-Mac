import Testing
import Foundation
@testable import LobsterOne

@MainActor @Test func debugLogCircularBuffer() {
    let log = DebugLog()
    let total = DebugLog.capacity + 10
    for i in 1...total {
        log.log("Entry \(i)")
    }
    #expect(log.entries.count == DebugLog.capacity)
    #expect(log.entries.first?.message == "Entry 11")
    #expect(log.entries.last?.message == "Entry \(total)")
}

@MainActor @Test func debugLogFormatted() {
    let log = DebugLog()
    log.log("Hello")
    log.log("World")
    let output = log.formatted
    #expect(output.contains("Hello"))
    #expect(output.contains("World"))
    #expect(output.contains("] "))
}

@Test func debugLogFlagsErrorLines() {
    #expect(DebugLogView.isError("Pace notification failed: denied"))
    #expect(DebugLogView.isError("[ClaudeScanner] Uploaded batch — HTTP 502, imported=0"))
    #expect(DebugLogView.isError("Claude token in Keychain expired 1d 9h ago (sub=max)"))
    #expect(!DebugLogView.isError("[ClaudeScanner] Uploaded batch — HTTP 200, imported=1"))
    #expect(!DebugLogView.isError("Anthropic quota OK: 5h=72%, 7d=67%"))
}

@MainActor @Test func debugLogRedactsSecrets() {
    #expect(DebugLog.redact("token=sk-ant-oat01-AbC_123-xyz rest") == "token=sk-ant-[redacted] rest")
    #expect(DebugLog.redact("Authorization: Bearer abc.def-123") == "Authorization: Bearer [redacted]")
    #expect(DebugLog.redact("key rc_0123456789abcdef0123") == "key rc_[redacted]")
    // Short key prefixes shown in Diagnostics stay readable.
    #expect(DebugLog.redact("keyPrefix=rc_4d37bb0...") == "keyPrefix=rc_4d37bb0...")

    let log = DebugLog()
    log.log("leak sk-ant-oat01-secret")
    #expect(log.entries.last?.message == "leak sk-ant-[redacted]")
}

private func tempLogDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lobsterone-log-test-\(UUID().uuidString)")
}

@MainActor @Test func debugLogWritesToFile() throws {
    let dir = tempLogDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = DebugLogFile(directory: dir)
    let log = DebugLog(file: file)
    log.log("Quota source: real")
    log.log("leak sk-ant-oat01-secret")
    file.flush()

    let text = try String(contentsOf: file.url, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].contains("--- LobsterOne/"))
    #expect(lines[1].hasSuffix(" Quota source: real"))
    #expect(lines[2].hasSuffix(" leak sk-ant-[redacted]"))
    #expect(!text.contains("secret"))

    let perms = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func debugLogFileRotates() throws {
    let dir = tempLogDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = DebugLogFile(directory: dir, maxBytes: 200, backups: 2)
    for i in 1...40 {
        file.append("line \(i) padding padding padding", at: Date())
    }
    file.flush()

    let fm = FileManager.default
    let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["debug.1.log", "debug.2.log", "debug.log"])
    for name in names {
        let size = try fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int ?? 0
        #expect(size < 300)
    }
    // The newest line is in the current file, older ones in the backups.
    let current = try String(contentsOf: file.url, encoding: .utf8)
    let newestBackup = try String(contentsOf: dir.appendingPathComponent("debug.1.log"), encoding: .utf8)
    #expect(current.contains("line 40 ") || newestBackup.contains("line 40 "))
    #expect(!current.contains("line 1 "))
}

@Test func tokenExpiryDescription() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func creds(expiresIn seconds: TimeInterval) -> ClaudeOAuthCredentials {
        let json = #"{"accessToken":"x","expiresAt":\#(Int64((now.timeIntervalSince1970 + seconds) * 1000))}"#
        return try! JSONDecoder().decode(ClaudeOAuthCredentials.self, from: Data(json.utf8))
    }
    #expect(creds(expiresIn: 7 * 3600 + 12 * 60).expiryDescription(now: now) == "valid for 7h 12m")
    #expect(creds(expiresIn: -(33 * 3600 + 5 * 60)).expiryDescription(now: now) == "expired 1d 9h ago")
    #expect(creds(expiresIn: -90).expiryDescription(now: now) == "expired 1m ago")
}

@Test func refreshOutputTail() {
    #expect(ClaudeCredentialService.tail(of: Data()) == "(none)")
    #expect(ClaudeCredentialService.tail(of: Data("Error: not logged in\n\n  run claude login\n".utf8)) == "Error: not logged in | run claude login")
    let long = String(repeating: "a", count: 1000) + "END"
    let tail = ClaudeCredentialService.tail(of: Data(long.utf8), limit: 50)
    #expect(tail.hasPrefix("…"))
    #expect(tail.hasSuffix("END"))
    #expect(tail.count == 51)
}

@Test func refreshCapturesExitCodeAndOutput() async {
    let outcome = await ClaudeCredentialService.runClaudeRefresh(
        claudePath: "/bin/sh", arguments: ["-c", "echo usage oops; echo boom >&2; exit 3"])
    #expect(outcome.launchError == nil)
    #expect(outcome.exitCode == 3)
    #expect(!outcome.timedOut)
    #expect(outcome.outputTail.contains("usage oops"))
    #expect(outcome.outputTail.contains("boom"))
}

@Test func refreshReportsTimeout() async {
    let outcome = await ClaudeCredentialService.runClaudeRefresh(
        claudePath: "/bin/sh", arguments: ["-c", "echo started; sleep 10"], timeout: 1)
    #expect(outcome.timedOut)
    #expect(outcome.duration < 5)
    #expect(outcome.outputTail.contains("started"))
}

@Test func refreshReportsLaunchFailure() async {
    let outcome = await ClaudeCredentialService.runClaudeRefresh(claudePath: "/nonexistent/claude")
    #expect(outcome.launchError != nil)
}
