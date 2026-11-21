import Testing
import Foundation
@testable import LobsterOne

@Test func parseCallbackParsesGitHubCode() throws {
    let url = URL(string: "lobsterone://auth/callback?code=AUTH_CODE_123&state=TEST_STATE")!
    #expect(AuthService.parseCallback(from: url) == .code(code: "AUTH_CODE_123", state: "TEST_STATE"))
}

@Test func parseCallbackParsesTokenFragment() throws {
    let url = URL(string: "lobsterone://auth/callback#id_token=ID.JWT&access_token=AC&refresh_token=RE&state=TEST_STATE")!
    #expect(AuthService.parseCallback(from: url) == .tokens(idToken: "ID.JWT", refreshToken: "RE", state: "TEST_STATE"))
}

@Test func parseCallbackReturnsNilOnMissingCodeAndTokens() {
    let url = URL(string: "lobsterone://auth/callback?error=access_denied")!
    #expect(AuthService.parseCallback(from: url) == nil)
}

@Test func parseCallbackRejectsWrongScheme() {
    let url = URL(string: "wrongscheme://auth/callback?code=AUTH_CODE_123&state=TEST_STATE")!
    #expect(AuthService.parseCallback(from: url) == nil)
}

@Test func parseCallbackRejectsWrongPath() {
    let url = URL(string: "lobsterone://auth/other?code=AUTH_CODE_123&state=TEST_STATE")!
    #expect(AuthService.parseCallback(from: url) == nil)
}

@Test func parseCallbackTokenFragmentRequiresRefreshToken() {
    let url = URL(string: "lobsterone://auth/callback#id_token=ID.JWT&state=TEST_STATE")!
    #expect(AuthService.parseCallback(from: url) == nil)
}

@Test func pkceVerifierIs43To128Chars() {
    let verifier = AuthService.generateCodeVerifier()
    #expect(verifier.count >= 43)
    #expect(verifier.count <= 128)
}

@Test func pkceChallengeDerivedFromVerifier() {
    let verifier = AuthService.generateCodeVerifier()
    let challenge = AuthService.codeChallenge(for: verifier)
    #expect(!challenge.isEmpty)
    #expect(challenge != verifier)
}

@Test func generateStateIsNonEmpty() {
    let state = AuthService.generateState()
    #expect(!state.isEmpty)
    #expect(state.count >= 32)
}
