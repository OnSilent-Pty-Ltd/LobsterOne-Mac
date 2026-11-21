import Testing
import Foundation
@testable import LobsterOne

@Test func parseQuotaResponse() throws {
    let json = """
    {
        "plan_tier": "pro",
        "plan_tier_source": "auto",
        "window_hours": 5,
        "limit_requests": 250,
        "used_requests": 188,
        "used_tokens": 1200000,
        "percent_used": 75.2,
        "burn_rate": {
            "requests_per_minute": 0.5,
            "tokens_per_minute": 3200,
            "minutes_until_limit": 124,
            "estimated_limit_at": "2026-03-16T14:00:00Z"
        },
        "next_recovery_at": "2026-03-16T10:00:00Z"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder().decode(QuotaResponse.self, from: json)
    #expect(response.planTier == "pro")
    #expect(response.limitRequests == 250)
    #expect(response.usedRequests == 188)
    #expect(response.usedTokens == 1_200_000)
    #expect(response.percentUsed == 75.2)

    let state = response.toQuotaState()
    #expect(state.menuBarText == "1.200M")
    #expect(state.statusLevel == .warning)
}

@Test @MainActor func apiClientBuildsCorrectHeaders() {
    let client = APIClient(baseURL: "https://api.lobsterone.ai", apiKey: "rc_test123")
    let request = client.buildRequest(path: "/v1/usage/quota", method: "GET")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "rc_test123")
    #expect(request.url?.absoluteString == "https://api.lobsterone.ai/v1/usage/quota")
}

@Test @MainActor func apiClientBuildsJWTHeaders() {
    let client = APIClient(baseURL: "https://api.lobsterone.ai")
    let request = client.buildRequest(path: "/v1/api-keys", method: "POST", bearerToken: "jwt_token_here")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt_token_here")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
}

@Test func apiErrorDisplayMessage() {
    let error401 = APIError.httpError(statusCode: 401, path: "/v1/usage/quota")
    #expect(error401.displayMessage == "401 Unauthorized on /v1/usage/quota")

    let error429 = APIError.httpError(statusCode: 429, path: "/v1/usage/realtime")
    #expect(error429.displayMessage == "429 Rate Limited on /v1/usage/realtime")

    let error500 = APIError.httpError(statusCode: 502, path: "/v1/usage/quota")
    #expect(error500.displayMessage == "502 Server Error on /v1/usage/quota")

    #expect(APIError.userNotFound.displayMessage == "User not found")
}

@MainActor @Test func apiClientSetsUserAgentHeaderOnEveryRequest() {
    let client = APIClient(baseURL: "https://test", apiKey: "test-key")

    let getReq = client.buildRequest(path: "/v1/usage/quota", method: "GET")
    let postReq = client.buildRequest(path: "/v1/usage/quota", method: "POST")

    let getUA = getReq.value(forHTTPHeaderField: "User-Agent") ?? ""
    let postUA = postReq.value(forHTTPHeaderField: "User-Agent") ?? ""

    #expect(getUA.hasPrefix("LobsterOne/"))
    #expect(postUA.hasPrefix("LobsterOne/"))
    #expect(getUA == postUA, "User-Agent should be identical across methods")
}

@MainActor @Test func apiClientUserAgentPresentEvenWithBearerToken() {
    let client = APIClient(baseURL: "https://test")
    let req = client.buildRequest(path: "/anything", method: "GET", bearerToken: "abc")
    let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
    #expect(ua.hasPrefix("LobsterOne/"))
}

@MainActor @Test func apiClientUserAgentOnInstanceQuotaPath() {
    // fetchQuotaForInstance and postQuotaSnapshot hand-roll URLRequest
    // (taking a per-call apiKey rather than using the instance's stored key)
    // — they must still carry the User-Agent.
    //
    // We can't easily intercept the URLRequest these methods build internally
    // without refactoring them through a seam. Instead, we assert that no
    // hand-rolled request path is missing the header by inspecting the source.
    // This is a guardrail test, not a behaviour test.
    //
    // Source-inspection assertion: the file must contain no `URLRequest(url:`
    // construction that doesn't have a `setValue(AppVersion.userAgent,` line
    // within ~10 lines below it.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LobsterOneTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // Robocog---Mac/
        .appendingPathComponent("Sources/LobsterOne/Services/APIClient.swift")

    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let lines = source.components(separatedBy: "\n")

    var missing: [Int] = []
    for (idx, line) in lines.enumerated() where line.contains("URLRequest(url:") {
        let window = lines[idx..<min(idx + 12, lines.count)].joined(separator: "\n")
        if !window.contains("AppVersion.userAgent") {
            missing.append(idx + 1)  // 1-indexed line numbers
        }
    }
    #expect(missing.isEmpty, "URLRequest(url:) at line(s) \(missing) of APIClient.swift is missing User-Agent setValue within 12 lines")
}
