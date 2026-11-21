import Testing
@testable import LobsterOne

@Test func textStreamEditAppendTypesOnlyTheNewWords() {
    let edit = TextStreamEdit(from: "fix the", to: "fix the failing test")
    #expect(edit == TextStreamEdit(backspaces: 0, insert: " failing test"))
}

@Test func textStreamEditNoChangeIsEmpty() {
    let edit = TextStreamEdit(from: "fix the test", to: "fix the test")
    #expect(edit.isEmpty)
}

@Test func textStreamEditRevisionInTheMiddleRetypesFromThere() {
    // "Weactor" became "We factor": the shared start is "We", everything after is retyped.
    let edit = TextStreamEdit(from: "Done. Weactor it", to: "Done. We factor it out")
    #expect(edit == TextStreamEdit(backspaces: 8, insert: " factor it out"))
}

@Test func textStreamEditRevisionAtTheStartRetypesEverything() {
    let edit = TextStreamEdit(from: "then run it", to: "Then run it")
    #expect(edit == TextStreamEdit(backspaces: 11, insert: "Then run it"))
}

@Test func textStreamEditShrinkOnlyDeletes() {
    let edit = TextStreamEdit(from: "run the tests um", to: "run the tests")
    #expect(edit == TextStreamEdit(backspaces: 3, insert: ""))
}

@Test func textStreamEditCountsEmojiAndAccentsAsOneBackspaceEach() {
    // 👍🏽 is two code points and four UTF-16 units; e + combining acute is two code points.
    let edit = TextStreamEdit(from: "ok 👍🏽 cafe\u{301}", to: "ok 👍")
    #expect(edit == TextStreamEdit(backspaces: 6, insert: "👍"))
    // A precomposed é is the same character as e + combining acute, so nothing changes.
    #expect(TextStreamEdit(from: "cafe\u{301}", to: "caf\u{E9}").isEmpty)
}

@Test func textStreamEditEmptyCases() {
    #expect(TextStreamEdit(from: "", to: "").isEmpty)
    #expect(TextStreamEdit(from: "", to: "hello") == TextStreamEdit(backspaces: 0, insert: "hello"))
    #expect(TextStreamEdit(from: "hello", to: "") == TextStreamEdit(backspaces: 5, insert: ""))
}
