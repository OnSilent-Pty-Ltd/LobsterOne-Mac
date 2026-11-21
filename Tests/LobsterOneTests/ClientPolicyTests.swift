import Testing
import Foundation
@testable import LobsterOne

@Test func decodesOkPolicy() throws {
    let json = #"{"level":"ok"}"#.data(using: .utf8)!
    let policy = try JSONDecoder().decode(ClientPolicy.self, from: json)
    #expect(policy.level == .ok)
    #expect(policy.message == nil)
    #expect(policy.downloadUrl == nil)
}

@Test func decodesSoftPolicyWithMessageAndDownloadUrl() throws {
    let json = #"""
    {
        "level": "soft",
        "message": "Update required by April 30",
        "download_url": "https://releases.lobsterone.ai/mac/LobsterOne-latest.dmg"
    }
    """#.data(using: .utf8)!
    let policy = try JSONDecoder().decode(ClientPolicy.self, from: json)
    #expect(policy.level == .soft)
    #expect(policy.message == "Update required by April 30")
    #expect(policy.downloadUrl == "https://releases.lobsterone.ai/mac/LobsterOne-latest.dmg")
}

@Test func decodesBlockPolicy() throws {
    let json = #"""
    {
        "level": "block",
        "message": "This version is no longer supported.",
        "download_url": "https://releases.lobsterone.ai/mac/LobsterOne-latest.dmg"
    }
    """#.data(using: .utf8)!
    let policy = try JSONDecoder().decode(ClientPolicy.self, from: json)
    #expect(policy.level == .block)
}

@Test func decodesUnknownLevelAsOk() throws {
    // Forward-compatibility: a future backend level we don't know about
    // should not break old clients. Decode-with-fallback-to-ok.
    let json = #"{"level":"future-unknown-level"}"#.data(using: .utf8)!
    let policy = try JSONDecoder().decode(ClientPolicy.self, from: json)
    #expect(policy.level == .ok)
}

@Test func statusResponseDecodesWithMissingClientPolicyAsNil() throws {
    // Pre-Plan-3 backend doesn't send the field; treat absence as nil
    // (which downstream code maps to ClientPolicy.okDefault).
    let json = #"""
    {
        "realtime": {
            "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "total": 0},
            "cost_usd": 0,
            "sessions": 0,
            "lines": {"added": 0, "removed": 0, "net": 0},
            "prs": 0,
            "commits": 0,
            "active_seconds": {"user": 0, "cli": 0, "total": 0}
        },
        "quota": {
            "plan_tier": "pro",
            "plan_tier_source": "auto",
            "window_hours": 5,
            "limit_requests": 250,
            "used_requests": 0,
            "used_tokens": 0,
            "percent_used": 0,
            "burn_rate": {
                "requests_per_minute": 0,
                "tokens_per_minute": 0,
                "minutes_until_limit": 0
            },
            "next_recovery_at": null
        }
    }
    """#.data(using: .utf8)!
    let resp = try JSONDecoder().decode(StatusResponse.self, from: json)
    #expect(resp.clientPolicy == nil)
}

@Test func statusResponseDecodesClientPolicyWhenPresent() throws {
    let json = #"""
    {
        "realtime": {
            "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "total": 0},
            "cost_usd": 0,
            "sessions": 0,
            "lines": {"added": 0, "removed": 0, "net": 0},
            "prs": 0,
            "commits": 0,
            "active_seconds": {"user": 0, "cli": 0, "total": 0}
        },
        "quota": {
            "plan_tier": "pro",
            "plan_tier_source": "auto",
            "window_hours": 5,
            "limit_requests": 250,
            "used_requests": 0,
            "used_tokens": 0,
            "percent_used": 0,
            "burn_rate": {
                "requests_per_minute": 0,
                "tokens_per_minute": 0,
                "minutes_until_limit": 0
            },
            "next_recovery_at": null
        },
        "client_policy": {
            "level": "block",
            "message": "Please update.",
            "download_url": "https://example.com/x.dmg"
        }
    }
    """#.data(using: .utf8)!
    let resp = try JSONDecoder().decode(StatusResponse.self, from: json)
    #expect(resp.clientPolicy?.level == .block)
    #expect(resp.clientPolicy?.message == "Please update.")
    #expect(resp.clientPolicy?.downloadUrl == "https://example.com/x.dmg")
}

@MainActor @Test func policyServiceStartsAtOk() {
    let defaults = UserDefaults(suiteName: "policy-test-\(UUID().uuidString)")!
    let service = ClientPolicyService(defaults: defaults)
    #expect(service.current.level == .ok)
}

@MainActor @Test func policyServiceUpdatePublishesNewValue() {
    let defaults = UserDefaults(suiteName: "policy-test-\(UUID().uuidString)")!
    let service = ClientPolicyService(defaults: defaults)
    let blocked = ClientPolicy(level: .block, message: "x", downloadUrl: "https://y")
    service.update(blocked)
    #expect(service.current.level == .block)
    #expect(service.current.message == "x")
}

@MainActor @Test func policyServiceUpdateNilTreatsAsOk() {
    // Backend sent no client_policy field at all → treat as ok.
    let defaults = UserDefaults(suiteName: "policy-test-\(UUID().uuidString)")!
    let service = ClientPolicyService(defaults: defaults)
    service.update(ClientPolicy(level: .block))
    service.update(nil)
    #expect(service.current.level == .ok)
}

@MainActor @Test func policyServicePersistsToDefaults() {
    let suite = "policy-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    let s1 = ClientPolicyService(defaults: defaults)
    s1.update(ClientPolicy(level: .block, message: "old", downloadUrl: "u"))

    // New service in same suite should hydrate to the persisted policy.
    let s2 = ClientPolicyService(defaults: defaults)
    #expect(s2.current.level == .block)
    #expect(s2.current.message == "old")
}

@MainActor @Test func policyServiceHydrateMissingDefaultsFallsBackToOk() {
    let defaults = UserDefaults(suiteName: "policy-test-\(UUID().uuidString)")!
    let service = ClientPolicyService(defaults: defaults)
    #expect(service.current.level == .ok)
}
