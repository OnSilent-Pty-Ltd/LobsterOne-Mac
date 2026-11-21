import Testing
import Foundation
@testable import LobsterOne

@Test func userAgentFormatIsLobsterOneSlashVersionParenBuild() {
    let ua = AppVersion.userAgent
    #expect(ua.hasPrefix("LobsterOne/"))
    #expect(ua.contains(" ("))
    #expect(ua.hasSuffix(")"))
}

@Test func userAgentFallsBackWhenInfoMissing() {
    // When run from the test bundle the Info.plist may not contain the keys;
    // make sure we never produce a header with empty or "nil" tokens.
    let ua = AppVersion.userAgent
    #expect(ua.contains("nil") == false)
    #expect(ua.contains("LobsterOne//") == false)
    #expect(ua.contains("()") == false)
}
