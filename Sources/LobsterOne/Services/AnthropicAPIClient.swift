import Foundation

enum AnthropicAPIError: Error {
    case httpError(statusCode: Int)
    case noCredentials
    case credentialsExpired

    var displayMessage: String {
        switch self {
        case .httpError(let code):
            switch code {
            case 401, 403: return "Auth failed (HTTP \(code)). Token may be expired."
            case 429: return "Rate limited by Anthropic API"
            default: return "Anthropic API error (HTTP \(code))"
            }
        case .noCredentials: return "No Claude credentials found"
        case .credentialsExpired: return "Claude token expired"
        }
    }
}

/// Client for Anthropic's OAuth usage API. Separate from APIClient (which targets lobsterone.ai).
@MainActor
final class AnthropicAPIClient {
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(accessToken: String) async throws -> AnthropicUsageResponse {
        var request = URLRequest(url: URL(string: Self.usageURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.anthropicOAuthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Log response body for non-2xx to diagnose team/business account issues
            let body = String(data: data.prefix(300), encoding: .utf8) ?? "(empty)"
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").map { ", retry-after=\($0)s" } ?? ""
            DebugLog.shared.log("Anthropic API HTTP \(statusCode)\(retryAfter) — body: \(body)")
            throw AnthropicAPIError.httpError(statusCode: statusCode)
        }

        do {
            return try JSONDecoder().decode(AnthropicUsageResponse.self, from: data)
        } catch {
            // Log the actual response shape to diagnose decoding failures
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = json.keys.sorted().joined(separator: ", ")
                DebugLog.shared.log("Anthropic API decode failed — response keys: [\(keys)], error: \(error)")
            } else {
                let preview = String(data: data.prefix(300), encoding: .utf8) ?? "(binary)"
                DebugLog.shared.log("Anthropic API decode failed — preview: \(preview)")
            }
            throw error
        }
    }
}
