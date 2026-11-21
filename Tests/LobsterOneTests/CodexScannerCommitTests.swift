import Testing
@testable import LobsterOne

@Test func codexCommitsCursorOnlyWhenSafe() {
    // Nothing to send → safe to advance the cursor.
    #expect(CodexSessionScanner.shouldCommitStates(hasEvents: false, forwardSucceeded: false) == true)
    // Sent and accepted → advance.
    #expect(CodexSessionScanner.shouldCommitStates(hasEvents: true,  forwardSucceeded: true)  == true)
    // Sent but rejected/failed → do NOT advance (re-send next scan).
    #expect(CodexSessionScanner.shouldCommitStates(hasEvents: true,  forwardSucceeded: false) == false)
}
