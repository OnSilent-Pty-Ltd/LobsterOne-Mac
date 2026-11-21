import Testing
import Foundation
@testable import LobsterOne

@Test func readCodexAPIKeyParsesUsersActualConfigShape() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let codexDir = tmpDir.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

    let toml = """
    model = 'gpt-5.4'

    [notice.model_migrations]
    'gpt-5.3-codex' = 'gpt-5.4'

    [otel]
    environment = 'production'
    log_user_prompt = false

        [otel.exporter.otlp-http]
        endpoint = 'https://ingest.lobsterone.ai/v1/logs'
        protocol = 'json'

            [otel.exporter.otlp-http.headers]
            x-api-key = 'rc_0123456789abcdef0123456789abcdef01234567'

        [otel.metrics_exporter.otlp-http]
        endpoint = 'https://ingest.lobsterone.ai/v1/metrics'
        protocol = 'json'

            [otel.metrics_exporter.otlp-http.headers]
            x-api-key = 'rc_0123456789abcdef0123456789abcdef01234567'

        [otel.trace_exporter.otlp-http]
        endpoint = 'https://ingest.lobsterone.ai/v1/traces'
        protocol = 'json'

            [otel.trace_exporter.otlp-http.headers]
            x-api-key = 'rc_0123456789abcdef0123456789abcdef01234567'

    [projects.'/Users/me/projects/example-cli']
    trust_level = 'trusted'
    """
    try toml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let config = ConfigService(homeDirectory: tmpDir)

    let key = config.readCodexAPIKey()
    #expect(key == "rc_0123456789abcdef0123456789abcdef01234567")

    let otel = config.checkCodexOtel()
    #expect(otel.configured == true)
    #expect(otel.endpoint == "https://ingest.lobsterone.ai/v1/logs")
    #expect(otel.keyPrefix == "rc_0123456...")
}
