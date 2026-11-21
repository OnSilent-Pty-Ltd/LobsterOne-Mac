import Testing
@testable import LobsterOne

@Test func dictationTextTrimsAndCollapsesSpaces() {
    #expect(DictationText.clean("  commit the   changes  ") == "commit the changes")
}

@Test func dictationTextFlattensNewlinesAndTabs() {
    // A newline pasted into a terminal prompt would submit half a sentence.
    #expect(DictationText.clean("open a pull\nrequest\r\n\tplease") == "open a pull request please")
}

@Test func dictationTextJoinsResultPiecesWithOneSpace() {
    #expect(DictationText.clean("Run the tests. " + " Then ship it.") == "Run the tests. Then ship it.")
}

@Test func dictationTextIsEmptyWhenNothingWasSaid() {
    #expect(DictationText.clean("") == "")
    #expect(DictationText.clean(" \n\t ") == "")
}

@Test func dictationTextKeepsPunctuationAndCase() {
    #expect(DictationText.clean("Hello, Garry! What's up?") == "Hello, Garry! What's up?")
}
