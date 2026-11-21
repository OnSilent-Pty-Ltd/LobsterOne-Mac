import Foundation
import Testing
@testable import LobsterOne

/// Records what it was asked to type and keeps a pretend field. Either call can be held open,
/// to play out updates arriving while keys are still being posted. Posts nothing.
@MainActor
private final class FakeTypist: TextStreamTypist {
    enum Call: Equatable { case type(String), backspace(Int) }

    private(set) var calls: [Call] = []
    private(set) var field = ""
    var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    var isHeld: Bool { gate != nil }

    func type(_ text: String) async -> Bool {
        calls.append(.type(text))
        await waitIfHeld()
        field += text
        return true
    }

    func backspace(_ count: Int) async -> Bool {
        calls.append(.backspace(count))
        await waitIfHeld()
        field = String(field.dropLast(count))
        return true
    }

    private func waitIfHeld() async {
        guard holdNext else { return }
        holdNext = false
        await withCheckedContinuation { gate = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class StreamHarness {
    let typist = FakeTypist()
    var frontmost: pid_t? = 100
    var accessibility = true
    var secureInput = false
    private(set) var streamer: TextStreamer!

    init() {
        streamer = TextStreamer(typist: typist, checks: .init(
            frontmostPID: { [weak self] in self?.frontmost },
            accessibility: { [weak self] in self?.accessibility ?? false },
            secureInput: { [weak self] in self?.secureInput ?? false }
        ))
    }

    func waitUntilHeld() async {
        for _ in 0..<1000 where !typist.isHeld { await Task.yield() }
    }
}

@MainActor @Suite
struct TextStreamerTests {
    @Test func appendsTypeOnlyTheNewWords() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("fix the")
        await h.streamer.settle()
        h.streamer.update("fix the failing test")
        let outcome = await h.streamer.finish("fix the failing test")
        #expect(outcome == .typed)
        #expect(h.typist.calls == [.type("fix the"), .type(" failing test")])
        #expect(h.typist.field == "fix the failing test")
    }

    @Test func aRevisionBackspacesThenTypes() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("then run")
        await h.streamer.settle()
        let outcome = await h.streamer.finish("Then run it")
        #expect(outcome == .typed)
        #expect(h.typist.calls == [.type("then run"), .backspace(8), .type("Then run it")])
        #expect(h.typist.field == "Then run it")
    }

    @Test func aBurstOfUpdatesCoalescesToTheNewest() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.typist.holdNext = true
        h.streamer.update("We")
        await h.waitUntilHeld()
        // Arrive while "We" is still being posted.
        h.streamer.update("Weactor")
        h.streamer.update("We fact")
        h.streamer.update("We factor it")
        h.typist.release()
        await h.streamer.settle()
        #expect(h.typist.calls == [.type("We"), .type(" factor it")])
        #expect(h.typist.field == "We factor it")
        #expect(await h.streamer.finish("We factor it") == .typed)
        #expect(h.typist.calls.count == 2)
    }

    @Test func theTargetMovingDuringBackspacesIsFollowed() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("then run")
        await h.streamer.settle()
        h.typist.holdNext = true
        h.streamer.update("Then")
        await h.waitUntilHeld()
        h.streamer.update("Then run it")
        h.typist.release()
        await h.streamer.settle()
        #expect(h.typist.calls == [.type("then run"), .backspace(8), .type("Then run it")])
        #expect(h.typist.field == "Then run it")
    }

    @Test func focusMovingStopsAllTypingAndFinishSaysInterrupted() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("hello")
        await h.streamer.settle()
        h.frontmost = 200
        h.streamer.update("hello there")
        await h.streamer.settle()
        h.frontmost = 100     // coming back doesn't resume: the field may have changed meanwhile
        let outcome = await h.streamer.finish("Hello there.")
        #expect(outcome == .interrupted(typedSoFar: "hello", reason: .focusMoved))
        #expect(h.typist.calls == [.type("hello")])
    }

    @Test func focusMovedBeforeTheFirstWordTypesNothing() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.frontmost = 200
        h.streamer.update("hello")
        #expect(await h.streamer.finish("hello") == .interrupted(typedSoFar: "", reason: .focusMoved))
        #expect(h.typist.calls.isEmpty)
    }

    @Test func secureInputOrLostAccessibilityStopsTyping() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.secureInput = true
        #expect(await h.streamer.finish("hello") == .interrupted(typedSoFar: "", reason: .secureInput))

        h.secureInput = false
        h.accessibility = false
        h.streamer.begin()
        #expect(await h.streamer.finish("hello") == .interrupted(typedSoFar: "", reason: .noAccessibility))
        #expect(h.typist.calls.isEmpty)
    }

    @Test func undoDeletesExactlyWhatWasTyped() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("ok 👍🏽 cafe\u{301}")
        await h.streamer.settle()
        #expect(h.streamer.hasTyped)
        await h.streamer.undo()
        #expect(h.typist.calls == [.type("ok 👍🏽 cafe\u{301}"), .backspace(9)])
        #expect(h.typist.field == "")
        #expect(!h.streamer.hasTyped)
    }

    @Test func undoAfterFocusMovedDeletesNothing() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("hello")
        await h.streamer.settle()
        h.frontmost = 200
        await h.streamer.undo()
        #expect(h.typist.calls == [.type("hello")])
    }

    @Test func nothingIsTypedOrDeletedAfterFinish() async {
        let h = StreamHarness()
        h.streamer.begin()
        #expect(await h.streamer.finish("done") == .typed)
        h.streamer.update("done and more")
        await h.streamer.undo()
        await h.streamer.settle()
        #expect(h.typist.calls == [.type("done")])
        #expect(h.typist.field == "done")
    }

    @Test func finishWithoutBeginTypesNothing() async {
        let h = StreamHarness()
        h.streamer.update("hello")
        #expect(await h.streamer.finish("hello") == .interrupted(typedSoFar: "", reason: .notStarted))
        #expect(h.typist.calls.isEmpty)
    }

    @Test func aNewRecordingWaitsForTheLastOnesUndo() async {
        let h = StreamHarness()
        h.streamer.begin()
        h.streamer.update("first")
        await h.streamer.settle()
        h.typist.holdNext = true
        let undo = Task { await h.streamer.undo() }
        await h.waitUntilHeld()
        h.streamer.begin()
        h.streamer.update("second")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.typist.calls == [.type("first"), .backspace(5)])
        h.typist.release()
        await undo.value
        #expect(await h.streamer.finish("second") == .typed)
        #expect(h.typist.calls == [.type("first"), .backspace(5), .type("second")])
        #expect(h.typist.field == "second")
    }
}

@Test func keyEventTypistChunksStayWithinTheEventLimit() {
    let long = String(repeating: "a", count: 45)
    #expect(KeyEventTypist.chunks(of: long).map(\.count) == [20, 20, 5])
    #expect(KeyEventTypist.chunks(of: "").isEmpty)
}

@Test func keyEventTypistChunksNeverSplitACharacter() {
    // Each 👍🏽 is four UTF-16 units, so five fit in an event and the sixth starts the next.
    let thumbs = String(repeating: "👍🏽", count: 6)
    let chunks = KeyEventTypist.chunks(of: thumbs)
    #expect(chunks == [String(repeating: "👍🏽", count: 5), "👍🏽"])
    #expect(chunks.allSatisfy { $0.utf16.count <= KeyEventTypist.maxUnitsPerEvent })
}
