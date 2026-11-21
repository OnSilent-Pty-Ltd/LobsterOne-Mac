import Testing
import Foundation
@testable import LobsterOne

/// A projects folder with one Claude Code session that used some tokens.
private func makeProjects(in root: URL) throws -> URL {
    let project = root.appendingPathComponent("projects/-Users-me-work-acme")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-11-21T05:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1200,"output_tokens":340}}}"#
    try (line + "\n").write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    return root.appendingPathComponent("projects")
}

private func cachedFileCount(_ cachePath: URL) throws -> Int {
    let data = try Data(contentsOf: cachePath)
    return try JSONDecoder().decode(ClaudeScannerCache.self, from: data).files.count
}

@MainActor
@Test func disconnectedClaudeCodeIsNotScannedOrSent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cachePath = root.appendingPathComponent("cache.json")

    let scanner = ClaudeSessionScanner(
        ingestURL: "http://127.0.0.1:9", projectsDir: try makeProjects(in: root),
        cachePath: cachePath, isConnected: { false })
    await scanner.forceRescan()

    #expect(try cachedFileCount(cachePath) == 0)
}

@MainActor
@Test func connectedClaudeCodeIsScanned() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cachePath = root.appendingPathComponent("cache.json")

    let scanner = ClaudeSessionScanner(
        ingestURL: "http://127.0.0.1:9", projectsDir: try makeProjects(in: root),
        cachePath: cachePath, isConnected: { true })
    await scanner.forceRescan()

    #expect(try cachedFileCount(cachePath) == 1)
}

@Test func disconnectingClaudeCodeClearsALegacyBackupKey() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent(".lobsterone")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"apiKey":"rc_legacy","configuredAt":"2026-03-01"}"#
        .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: home)
    #expect(config.readAPIKey() == "rc_legacy")
    try config.removeConfig()
    #expect(config.readAPIKey() == nil)
}
