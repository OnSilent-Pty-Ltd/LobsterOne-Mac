import Foundation
import Testing
@testable import LobsterOne

/// A stand-in for `claude plugin …`: answers from a script and records every call.
private actor FakeClaude {
    var calls: [[String]] = []
    var installed = false
    var enabled = true
    var refuseInstall: String?

    func run(_ arguments: [String]) -> ClaudeCodeMod.Output {
        calls.append(arguments)
        switch Array(arguments.prefix(3)) {
        case ["plugin", "list", "--json"]:
            let rows = installed ? #"[{"id":"lobsterone@lobsterone","version":"0.8.0","folderVersion":"0.8.0","enabled":\#(enabled)}]"# : "[]"
            return .init(status: 0, stdout: rows, stderr: "")
        case ["plugin", "marketplace", "add"]:
            return .init(status: 0, stdout: #"{"ok":true}"#, stderr: "")
        case ["plugin", "install", ClaudeCodeMod.pluginID]:
            if let refuseInstall { return .init(status: 1, stdout: #"{"error":"\#(refuseInstall)"}"#, stderr: "") }
            if installed { return .init(status: 1, stdout: "", stderr: "Plugin is already installed") }
            installed = true
            return .init(status: 0, stdout: #"{"ok":true}"#, stderr: "")
        case ["plugin", "enable", ClaudeCodeMod.pluginID]:
            enabled = true
            return .init(status: 0, stdout: #"{"ok":true}"#, stderr: "")
        case ["plugin", "uninstall", ClaudeCodeMod.pluginID]:
            installed = false
            return .init(status: 0, stdout: #"{"ok":true}"#, stderr: "")
        default:
            return .init(status: 0, stdout: "", stderr: "")
        }
    }

    func setInstalled(_ value: Bool, enabled: Bool = true) {
        installed = value
        self.enabled = enabled
    }

    func refuse(_ words: String) { refuseInstall = words }
}

/// A bundled mod, an empty place to install it and a portrait, in a fresh temporary folder.
private func folders(version: String = "0.8.0") throws -> (bundled: URL, installed: URL, portrait: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-mod-\(UUID().uuidString)")
    let bundled = root.appendingPathComponent("bundle/lobsterone")
    try FileManager.default.createDirectory(at: bundled.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundled.appendingPathComponent("hooks"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundled.appendingPathComponent("tests"), withIntermediateDirectories: true)
    try #"{"name":"lobsterone","version":"\#(version)"}"#.write(to: bundled.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
    try "export const register = () => {}".write(to: bundled.appendingPathComponent("hooks/register.tsx"), atomically: true, encoding: .utf8)
    try "test".write(to: bundled.appendingPathComponent("tests/look.test.tsx"), atomically: true, encoding: .utf8)
    let portrait = root.appendingPathComponent("crew-wren.jpg")
    try Data([0xFF, 0xD8]).write(to: portrait)
    return (bundled, root.appendingPathComponent("support/ClaudeCode/lobsterone"), portrait)
}

private func mod(_ fake: FakeClaude?, _ f: (bundled: URL, installed: URL, portrait: URL), bundled: Bool = true) -> ClaudeCodeMod {
    ClaudeCodeMod(bundledURL: bundled ? f.bundled : nil,
                  installedURL: f.installed,
                  portraits: [f.portrait],
                  claude: fake.map { fake in { arguments in await fake.run(arguments) } })
}

@Test func withoutClaudeCodeTheModCantBeAdded() async throws {
    let f = try folders()
    let m = mod(nil, f)
    #expect(await m.state() == .claudeMissing)
    await #expect(throws: ClaudeCodeMod.Failure.claudeMissing) { try await m.install() }
    #expect(!FileManager.default.fileExists(atPath: f.installed.path))
}

@Test func addingCopiesTheModWithPortraitsAndInstallsItFromThere() async throws {
    let f = try folders()
    let fake = FakeClaude()
    let m = mod(fake, f)
    #expect(await m.state() == .notInstalled)

    try await m.install()

    #expect(FileManager.default.fileExists(atPath: f.installed.appendingPathComponent("hooks/register.tsx").path))
    #expect(FileManager.default.fileExists(atPath: f.installed.appendingPathComponent("portraits/crew-wren.jpg").path))
    // The repo's tests stay behind.
    #expect(!FileManager.default.fileExists(atPath: f.installed.appendingPathComponent("tests").path))
    let calls = await fake.calls
    #expect(calls.contains(["plugin", "marketplace", "add", f.installed.path, "--json"]))
    #expect(calls.contains(["plugin", "install", ClaudeCodeMod.pluginID, "--scope", "user", "--yes", "--json"]))
    #expect(await m.state() == .installed(version: "0.8.0"))
}

@Test func addingTwiceIsFineAndTurnsASwitchedOffModBackOn() async throws {
    let f = try folders()
    let fake = FakeClaude()
    let m = mod(fake, f)
    try await m.install()
    await fake.setInstalled(true, enabled: false)
    #expect(await m.state() == .switchedOff(version: "0.8.0"))

    try await m.install()

    #expect(await m.state() == .installed(version: "0.8.0"))
}

@Test func aRefusalIsReportedInClaudeCodesOwnWords() async throws {
    let f = try folders()
    let fake = FakeClaude()
    await fake.refuse("Plugins are disabled by your organization's policy")
    let m = mod(fake, f)

    await #expect(throws: ClaudeCodeMod.Failure.claudeSaid("Plugins are disabled by your organization's policy")) {
        try await m.install()
    }
}

@Test func removingUninstallsForgetsTheFolderAndDeletesTheFiles() async throws {
    let f = try folders()
    let fake = FakeClaude()
    let m = mod(fake, f)
    try await m.install()

    try await m.remove()

    #expect(!FileManager.default.fileExists(atPath: f.installed.path))
    let calls = await fake.calls
    #expect(calls.contains(["plugin", "uninstall", ClaudeCodeMod.pluginID, "--json"]))
    #expect(calls.contains(["plugin", "marketplace", "remove", ClaudeCodeMod.marketplaceName, "--json"]))
    #expect(await m.state() == .notInstalled)
}

@Test func anAppUpdateReplacesAnOlderCopyButNeverAddsOne() async throws {
    let f = try folders(version: "0.9.0")
    let fake = FakeClaude()
    let m = mod(fake, f)
    // Not added: an update leaves Claude Code alone.
    #expect(try m.refreshFiles() == false)
    #expect(!FileManager.default.fileExists(atPath: f.installed.path))

    try await m.install()
    try #"{"name":"lobsterone","version":"0.8.0"}"#.write(to: f.installed.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
    #expect(try m.refreshFiles() == true)
    #expect(ClaudeCodeMod.version(at: f.installed) == "0.9.0")
    #expect(try m.refreshFiles() == false)
}

@Test func aBuildWithoutTheModSaysSoWhenNothingIsInstalled() async throws {
    let f = try folders()
    let m = mod(FakeClaude(), f, bundled: false)
    #expect(await m.state() == .notBundled)
}

@Test func versionsCompareByNumberNotByText() {
    #expect(ClaudeCodeMod.isNewer("0.10.0", than: "0.9.4"))
    #expect(ClaudeCodeMod.isNewer("1.0", than: nil))
    #expect(!ClaudeCodeMod.isNewer("0.8.0", than: "0.8.0"))
    #expect(!ClaudeCodeMod.isNewer("0.8", than: "0.8.1"))
}

@Test func claudeCodesReasonComesFromItsJSONLineOrItsFirstLine() {
    #expect(ClaudeCodeMod.words(.init(status: 1, stdout: "noise\n{\"error\":\"Marketplace not found\"}", stderr: "")) == "Marketplace not found")
    #expect(ClaudeCodeMod.words(.init(status: 1, stdout: "", stderr: "Error: unknown command\n  at …")) == "Error: unknown command")
    #expect(ClaudeCodeMod.words(.init(status: 3, stdout: "", stderr: "")) == "it stopped with code 3.")
}
