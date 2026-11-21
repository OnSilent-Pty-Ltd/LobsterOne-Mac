import Testing
import Foundation
@testable import LobsterOne

// MARK: - Anthropic Usage API Decoding Tests

@Test func extraUsageDecodesNullMonthlyLimit() throws {
    // Accounts without an extra-usage cap return monthly_limit: null.
    // A non-optional Double here fails the WHOLE response decode and the
    // app silently falls back to P90 quota estimates.
    let json = """
    {"five_hour":{"utilization":4.0,"resets_at":"2026-07-11T10:00:00Z"},
     "seven_day":{"utilization":2.0,"resets_at":null},
     "extra_usage":{"is_enabled":true,"used_credits":null,"monthly_limit":null}}
    """
    let decoded = try JSONDecoder().decode(AnthropicUsageResponse.self, from: json.data(using: .utf8)!)
    #expect(decoded.fiveHour?.utilization == 4.0)
    #expect(decoded.extraUsage?.isEnabled == true)
    #expect(decoded.extraUsage?.monthlyLimit == nil)
}

@Test func extraUsageDecodesPopulatedMonthlyLimit() throws {
    let json = """
    {"extra_usage":{"is_enabled":true,"used_credits":1250.0,"monthly_limit":5000.0}}
    """
    let decoded = try JSONDecoder().decode(AnthropicUsageResponse.self, from: json.data(using: .utf8)!)
    #expect(decoded.extraUsage?.monthlyLimit == 5000.0)
    #expect(decoded.extraUsage?.usedCredits == 1250.0)
}

@Test func usageResponseIgnoresUnknownKeys() throws {
    // The API adds experimental keys freely (seven_day_cowork, spend, ...) —
    // decoding must not depend on an exhaustive key list.
    let json = """
    {"five_hour":{"utilization":1.5,"resets_at":null},
     "amber_ladder":{"whatever":true},
     "seven_day_cowork":{"utilization":0.0}}
    """
    let decoded = try JSONDecoder().decode(AnthropicUsageResponse.self, from: json.data(using: .utf8)!)
    #expect(decoded.fiveHour?.utilization == 1.5)
    #expect(decoded.extraUsage == nil)
}
