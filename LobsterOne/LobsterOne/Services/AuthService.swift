import AuthenticationServices
import CryptoKit
import Foundation

enum CallbackResult: Equatable {
    case code(code: String, state: String)
    case tokens(idToken: String, refreshToken: String, state: String)
}

@MainActor
final class AuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let cognitoDomain = "auth.lobsterone.ai"
    static let clientId = "2js3fq924qid6j09sc9r9b1mak"
    nonisolated static let callbackScheme = "lobsterone"
    static let redirectURI = "lobsterone://auth/callback"
    static let webLoginURL = "https://app.lobsterone.ai/auth/login"

    nonisolated(unsafe) private weak var presentationWindow: NSWindow?

    struct AuthResult {
        let idToken: String
        let refreshToken: String
        let email: String?
    }

    struct TokenResponse: Decodable {
        let id_token: String
        let access_token: String
        let refresh_token: String? // Cognito omits this on refresh grant
        let expires_in: Int
        let token_type: String
    }

    nonisolated init(presentationWindow: NSWindow? = nil) {
        self.presentationWindow = presentationWindow
    }

    // MARK: - PKCE

    nonisolated static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Auth Code Parsing

    nonisolated static func parseCallback(from url: URL) -> CallbackResult? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard url.scheme == callbackScheme, url.host == "auth", url.path == "/callback" else {
            return nil
        }

        // GitHub path: ?code=...&state=...
        if let queryItems = components?.queryItems,
           let code = queryItems.first(where: { $0.name == "code" })?.value,
           let state = queryItems.first(where: { $0.name == "state" })?.value {
            return .code(code: code, state: state)
        }

        // Email/password path: #id_token=...&refresh_token=...&state=...
        if let fragment = components?.fragment {
            let pairs = fragment.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    dict[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
            if let idToken = pairs["id_token"],
               let refreshToken = pairs["refresh_token"],
               let state = pairs["state"] {
                return .tokens(idToken: idToken, refreshToken: refreshToken, state: state)
            }
        }

        return nil
    }

    // MARK: - Sign In (Authorization Code + PKCE)

    func signIn() async throws -> AuthResult {
        precondition(!Self.clientId.isEmpty, "AuthService.clientId must be set. Deploy CDK (Task 12) and update this value.")
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.generateState()

        let authURL = buildAuthURL(codeChallenge: codeChallenge, state: state)
        let callbackURL = try await performWebAuth(url: authURL)

        guard let result = Self.parseCallback(from: callbackURL) else {
            throw AuthError.codeParsingFailed
        }

        switch result {
        case let .code(code, returnedState):
            guard returnedState == state else { throw AuthError.codeParsingFailed }
            let tokenResponse = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
            guard let refreshToken = tokenResponse.refresh_token else {
                throw AuthError.tokenExchangeFailed
            }
            return AuthResult(
                idToken: tokenResponse.id_token,
                refreshToken: refreshToken,
                email: decodeEmailFromJWT(tokenResponse.id_token)
            )

        case let .tokens(idToken, refreshToken, returnedState):
            guard returnedState == state else { throw AuthError.codeParsingFailed }
            return AuthResult(
                idToken: idToken,
                refreshToken: refreshToken,
                email: decodeEmailFromJWT(idToken)
            )
        }
    }

    // MARK: - Token Refresh

    func refreshTokens(refreshToken: String) async throws -> TokenResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.cognitoDomain
        components.path = "/oauth2/token"

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "client_id=\(Self.clientId)",
            "refresh_token=\(refreshToken)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AuthError.tokenRefreshFailed
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    func createAPIKeyWithRetry(apiClient: APIClient, idToken: String, label: String = "LobsterOne Mac App", sourceType: String? = nil) async throws -> CreateAPIKeyResponse {
        let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]
        var lastError: Error?

        for (index, delay) in delays.enumerated() {
            do {
                return try await apiClient.createAPIKey(label: label, bearerToken: idToken, sourceType: sourceType)
            } catch APIError.userNotFound {
                lastError = APIError.userNotFound
                if index < delays.count - 1 {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        do {
            return try await apiClient.createAPIKey(label: label, bearerToken: idToken, sourceType: sourceType)
        } catch {
            throw lastError ?? error
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            presentationWindow ?? NSApp.keyWindow ?? NSWindow()
        }
    }

    // MARK: - Private

    private func buildAuthURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: Self.webLoginURL)!
        components.queryItems = [
            URLQueryItem(name: "desktop", value: "1"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]
        return components.url!
    }

    private func performWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> TokenResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.cognitoDomain
        components.path = "/oauth2/token"

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "client_id=\(Self.clientId)",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI)",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func decodeEmailFromJWT(_ token: String) -> String? {
        Self.email(fromIDToken: token)
    }

    /// The email claim of an ID token. JWT segments are base64url without padding.
    nonisolated static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }
}

enum AuthError: Error {
    case codeParsingFailed
    case tokenExchangeFailed
    case tokenRefreshFailed
    case cancelled
}
