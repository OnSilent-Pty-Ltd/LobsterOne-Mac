import Testing
@testable import LobsterOne

@Test func vibeCommitsCursorOnlyWhenSafe() {
    #expect(MistralVibeSessionScanner.shouldCommitStates(hasEvents: false, forwardSucceeded: false) == true)
    #expect(MistralVibeSessionScanner.shouldCommitStates(hasEvents: true,  forwardSucceeded: true)  == true)
    #expect(MistralVibeSessionScanner.shouldCommitStates(hasEvents: true,  forwardSucceeded: false) == false)
}
