import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Puts keystrokes into whatever has focus. Behind a protocol so the streamer's ordering and
/// focus rules can be tested with a fake that only records what it was asked to do.
@MainActor
protocol TextStreamTypist: AnyObject {
    /// False when the events couldn't be made, in which case none were posted.
    func type(_ text: String) async -> Bool
    func backspace(_ count: Int) async -> Bool
}

/// Types the live transcript into the focused field while the person is still speaking, and
/// corrects it as the speech model settles each sentence.
///
/// Each update only says what the field should hold now. One worker turns that into keystrokes
/// (`TextStreamEdit`): usually just the new words, sometimes a few Backspaces first when the
/// model rewrites the sentence in progress. Updates arriving while it types are not queued; the
/// worker always heads for the newest one, so a burst costs one edit rather than many.
///
/// It never types into an app the person didn't start in: once the app in front changes, or
/// keystrokes can no longer be posted, this recording types nothing more, and a later undo
/// deletes nothing.
@MainActor
final class TextStreamer {
    enum Outcome: Equatable {
        case typed
        /// Typing stopped early; `typedSoFar` is what was left in the field.
        case interrupted(typedSoFar: String, reason: StopReason)
    }

    enum StopReason: Equatable { case focusMoved, noAccessibility, secureInput, postFailed, notStarted }

    /// What the streamer checks before every edit, swappable for tests.
    struct Checks {
        var frontmostPID: @MainActor () -> pid_t?
        var accessibility: @MainActor () -> Bool
        var secureInput: @MainActor () -> Bool

        static let live = Checks(
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            accessibility: { AXIsProcessTrusted() },
            secureInput: { IsSecureEventInputEnabled() }
        )
    }

    /// One recording's typing. A new recording gets a new one, so nothing about the last
    /// recording (what it typed, why it stopped) can leak into the next.
    @MainActor
    private final class Session {
        let pid: pid_t?
        /// What this recording has put in the field.
        var typed = ""
        /// What the field should hold.
        var target = ""
        /// Finished or undone: later updates are ignored.
        var closed = false
        var stopped: StopReason?
        var worker: Task<Void, Never>?

        init(pid: pid_t?) { self.pid = pid }
    }

    private let typist: TextStreamTypist
    private let checks: Checks
    private var session: Session?
    /// The last worker started, from any recording. A new one waits for it, so a quick second
    /// press can't type over the first one's undo.
    private var lastWork: Task<Void, Never>?

    /// Nil parameters mean the real thing; tests pass fakes.
    init(typist: TextStreamTypist? = nil, checks: Checks? = nil) {
        self.typist = typist ?? KeyEventTypist()
        self.checks = checks ?? .live
    }

    /// Whether this recording has text in the field right now.
    var hasTyped: Bool { !(session?.typed.isEmpty ?? true) }

    /// Starts a recording's typing in the app in front now.
    func begin() {
        session?.closed = true
        session = Session(pid: checks.frontmostPID())
    }

    /// The field should now hold `target`. Returns at once.
    func update(_ target: String) {
        guard let session, !session.closed else { return }
        session.target = target
        work(on: session)
    }

    /// Types the last correction and waits until the field matches, or typing has stopped.
    func finish(_ final: String) async -> Outcome {
        guard let session, !session.closed else { return .interrupted(typedSoFar: "", reason: .notStarted) }
        session.target = final
        session.closed = true
        work(on: session)
        await drain(session)
        if let reason = session.stopped {
            DebugLog.shared.log("Dictation typing: stopped (\(reason)) with \(session.typed.count) characters typed")
            return .interrupted(typedSoFar: session.typed, reason: reason)
        }
        DebugLog.shared.log("Dictation typing: typed \(session.typed.count) characters")
        return .typed
    }

    /// Deletes everything this recording typed, if it is still in the app it was typed into.
    /// Does nothing once the recording has finished, so a stale undo can't eat a new recording's
    /// text or the last one's.
    func undo() async {
        guard let session, !session.closed else { return }
        let count = session.typed.count
        session.target = ""
        session.closed = true
        work(on: session)
        await drain(session)
        if let reason = session.stopped {
            DebugLog.shared.log("Dictation typing: couldn't undo (\(reason)), left \(session.typed.count) characters")
        } else {
            DebugLog.shared.log("Dictation typing: undid \(count) characters")
        }
    }

    /// Waits until the field matches the newest target, or typing has stopped. For tests.
    func settle() async {
        if let session { await drain(session) }
    }

    // MARK: Worker

    private func work(on session: Session) {
        guard session.worker == nil, session.stopped == nil, session.typed != session.target else { return }
        let previous = lastWork
        let task = Task {
            await previous?.value
            await self.apply(session)
            session.worker = nil
        }
        session.worker = task
        lastWork = task
    }

    private func drain(_ session: Session) async {
        while let worker = session.worker { await worker.value }
    }

    /// Edits until the field holds the newest target. After the Backspaces of an edit it looks
    /// again before typing, since the target may have moved on while they were posted.
    private func apply(_ session: Session) async {
        while session.stopped == nil, session.typed != session.target {
            if let reason = blocker(for: session) {
                session.stopped = reason
                return
            }
            let edit = TextStreamEdit(from: session.typed, to: session.target)
            if edit.backspaces > 0 {
                guard await typist.backspace(edit.backspaces) else {
                    session.stopped = .postFailed
                    return
                }
                session.typed = String(session.typed.dropLast(edit.backspaces))
                continue
            }
            guard await typist.type(edit.insert) else {
                session.stopped = .postFailed
                return
            }
            session.typed += edit.insert
        }
    }

    /// Why typing must stop now, if it must. Typing on into an app the person switched to would
    /// put words, or Backspaces, somewhere they never meant.
    private func blocker(for session: Session) -> StopReason? {
        guard let pid = session.pid, checks.frontmostPID() == pid else { return .focusMoved }
        if !checks.accessibility() { return .noAccessibility }
        if checks.secureInput() { return .secureInput }
        return nil
    }
}

/// Posts text as synthetic key events that carry the characters themselves, and Backspaces.
/// No clipboard, so the person's clipboard is never touched while they speak.
///
/// Not verified live: the person is holding the dictation shortcut, a modifier or a
/// combination's modifiers, the whole time this types. Every event comes from a private event
/// source and has its flags set to none explicitly, which keeps our own source's modifier state
/// out. Whether macOS still merges the physically held modifier into events posted at the HID
/// tap is not known. If it does, a Backspace arrives as ⌥⌫ and deletes a word, and letters
/// arrive as ⌥-letters, which terminals set to "Option as Meta" read as commands.
///
/// `CGEventSource`'s local-event suppression settings were considered and left alone: the
/// CoreGraphics header says the system does not suppress the person's own keys after a posted
/// event by default, so there is nothing to turn off.
@MainActor
final class KeyEventTypist: TextStreamTypist {
    /// CGEventKeyboardSetUnicodeString carries at most this many UTF-16 units per event.
    nonisolated static let maxUnitsPerEvent = 20
    /// Between keystrokes, so slower apps keep up. Rewriting a 60-character sentence is about
    /// 60 Backspaces and 3 text events: well under a third of a second.
    nonisolated static let gap: Duration = .milliseconds(2)

    func type(_ text: String) async -> Bool {
        // Made up front so a failure posts nothing, and the streamer's idea of the field stays right.
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var strokes: [(CGEvent, CGEvent)] = []
        for chunk in Self.chunks(of: text) {
            guard let down = makeEvent(source, keyCode: 0, down: true),
                  let up = makeEvent(source, keyCode: 0, down: false)
            else { return false }
            let units = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            strokes.append((down, up))
        }
        await post(strokes)
        return true
    }

    func backspace(_ count: Int) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var strokes: [(CGEvent, CGEvent)] = []
        for _ in 0..<max(count, 0) {
            guard let down = makeEvent(source, keyCode: CGKeyCode(kVK_Delete), down: true),
                  let up = makeEvent(source, keyCode: CGKeyCode(kVK_Delete), down: false)
            else { return false }
            strokes.append((down, up))
        }
        await post(strokes)
        return true
    }

    /// Flags set to none on every event: the private source never posts a modifier, and this
    /// says outright that none is meant.
    private func makeEvent(_ source: CGEventSource, keyCode: CGKeyCode, down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
        event.flags = []
        // The dictation hotkey skips events carrying this, so our keys never count as a chord.
        event.setIntegerValueField(.eventSourceUserData, value: TextPaster.syntheticEventMarker)
        return event
    }

    private func post(_ strokes: [(CGEvent, CGEvent)]) async {
        for (index, stroke) in strokes.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.gap) }
            stroke.0.post(tap: .cghidEventTap)
            stroke.1.post(tap: .cghidEventTap)
        }
    }

    /// Splits text into pieces of at most `limit` UTF-16 units without cutting a character in
    /// two. A single character longer than that (a long emoji sequence) goes on its own.
    nonisolated static func chunks(of text: String, limit: Int = maxUnitsPerEvent) -> [String] {
        var chunks: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let size = character.utf16.count
            if units + size > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
