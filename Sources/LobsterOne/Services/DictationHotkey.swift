import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Watches the dictation shortcut for hold-to-talk and turns key events into begin / commit /
/// discard.
///
/// A lone modifier (Right Option by default) is watched with NSEvent monitors rather than a
/// CGEventTap: far less code, and the only permission they need for other apps' keys is
/// Accessibility, which the paste needs anyway. The global monitor sees events sent to other
/// apps, the local one events sent to LobsterOne's own windows. Monitors only observe, so the
/// modifier still reaches the app the person is typing in, which is harmless for a modifier.
///
/// A combination (⌃⌥Space) is a Carbon hotkey instead. Monitors can't stop a Space reaching the
/// front app; a hotkey swallows it, needs no permission, and still fires under Secure Input.
/// The monitors stay on in that mode, but only for Escape: the person is holding modifiers as
/// part of the shortcut, so their other keys and clicks aren't a chord to discard.
@MainActor
final class DictationHotkey {
    enum ShortcutError: Error, Equatable {
        /// Another app or macOS already uses the combination. The text is shown in Settings.
        case taken(String)
    }

    var onBegin: () -> Void = {}
    var onCommit: () -> Void = {}
    var onDiscard: () -> Void = {}

    /// While recording, how often to check that the key is really still down. A release can be
    /// missed (secure input swallowing it, a monitor re-armed mid-press), and without this the
    /// microphone would stay open until the next press.
    nonisolated static let releaseCheckInterval: TimeInterval = 0.25

    /// "LOBS", so the hotkey handler can tell our hotkey from any other in the process.
    nonisolated static let hotKeySignature: OSType = 0x4C4F_4253
    nonisolated static let hotKeyID: UInt32 = 1

    private(set) var shortcut: DictationShortcut = .defaultValue
    private var detector = HoldDetector()
    private var monitors: [Any] = []
    private var wakeObserver: NSObjectProtocol?
    private var releaseTimer: Timer?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private(set) var isRunning = false

    nonisolated init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installMonitors()
        installHotKeyHandler()
        do {
            try registerHotKey()
        } catch {
            // The combination was free when it was chosen; something has taken it since.
            DebugLog.shared.log("Dictation key: couldn't register \(shortcut.displayName) (\(error))")
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmAfterWake() }
        }
        DebugLog.shared.log("Dictation key: listening for \(shortcut.displayName)")
    }

    /// Removes the monitors, the hotkey and the timers. A recording in progress is discarded.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeMonitors()
        unregisterHotKey()
        removeHotKeyHandler()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        dropPress()
        DebugLog.shared.log("Dictation key: stopped")
    }

    /// Switches to another shortcut. A press in progress is thrown away, since it belonged to
    /// the old one. Throws, and keeps the old shortcut, when a combination is already taken.
    /// While stopped the combination is still tried once, so Settings can refuse it at once.
    func setShortcut(_ new: DictationShortcut) throws {
        guard new != shortcut else { return }
        if let reason = Self.systemShortcutUsing(new) { throw ShortcutError.taken(reason) }
        if isRunning {
            dropPress()
            unregisterHotKey()
            let old = shortcut
            shortcut = new
            do {
                try registerHotKey()
            } catch {
                shortcut = old
                try? registerHotKey()
                throw error
            }
        } else {
            // Registered and let go straight away, only to learn whether it is free.
            if let ref = try Self.register(new) { UnregisterEventHotKey(ref) }
            shortcut = new
        }
        DebugLog.shared.log("Dictation key: shortcut is now \(new.displayName)")
    }

    /// Discards a recording under way and forgets the press, so nothing from it carries over.
    private func dropPress() {
        if let output = detector.reset() { deliver(output) }
        stopReleaseTimer()
    }

    // MARK: Monitors

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        // Both kinds of monitor call back on the main thread.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// Monitors installed before sleep can stop delivering after wake. Nobody is holding the key
    /// across a sleep, so a recording still open is thrown away rather than committed.
    private func rearmAfterWake() {
        guard isRunning else { return }
        removeMonitors()
        installMonitors()
        dropPress()
        DebugLog.shared.log("Dictation key: re-armed after wake")
    }

    // MARK: Events

    private func handle(_ event: NSEvent) {
        // This runs for every key and click on the Mac. Unless a hold is under way, only a
        // modifier going down or up can matter, so everything else leaves before any work.
        if event.type != .flagsChanged, !detector.isHolding { return }

        // Our own ⌘V. It arrives after a commit, when the detector is idle and would ignore it
        // anyway, but skipping it outright keeps a new press during the paste from being
        // mistaken for a chord.
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextPaster.syntheticEventMarker { return }

        guard case .modifier(let key) = shortcut else {
            // The hotkey reports the combination itself; here only Escape matters.
            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                feed(.otherKeyDown(isEscape: true), at: event.timestamp)
            }
            return
        }

        let input: HoldDetector.Input
        var othersHeld = false
        switch event.type {
        case .flagsChanged:
            if event.keyCode == key.keyCode {
                let raw = UInt64(event.modifierFlags.rawValue)
                input = key.isDown(rawFlags: raw) ? .triggerDown : .triggerUp
                othersHeld = key.hasOtherModifiers(rawFlags: raw)
            } else {
                input = .otherModifierDown
            }
        case .keyDown:
            input = .otherKeyDown(isEscape: event.keyCode == UInt16(kVK_Escape))
        case .leftMouseDown, .rightMouseDown:
            input = .mouseDown
        default:
            return
        }
        feed(input, at: event.timestamp, otherModifiersHeld: othersHeld)
    }

    private func feed(_ input: HoldDetector.Input, at time: TimeInterval, otherModifiersHeld: Bool = false) {
        guard let output = detector.handle(input, at: time, otherModifiersHeld: otherModifiersHeld) else { return }
        deliver(output)
    }

    private func deliver(_ output: HoldDetector.Output) {
        switch output {
        case .begin:
            startReleaseTimer()
            onBegin()
        case .commit:
            stopReleaseTimer()
            onCommit()
        case .discard:
            stopReleaseTimer()
            onDiscard()
        }
    }

    // MARK: Hotkey

    /// One handler for press and release, installed on start. It sits on the event dispatcher
    /// target, so it fires whichever app is in front.
    private func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }
        var kinds = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Unretained: stop() removes the handler, and the controller keeps this object for the
        // life of the app.
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), Self.hotKeyCallback,
                                         kinds.count, &kinds, me, &hotKeyHandler)
        if status != noErr {
            DebugLog.shared.log("Dictation key: couldn't install the hotkey handler (\(status))")
            hotKeyHandler = nil
        }
    }

    private func removeHotKeyHandler() {
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    /// Registers the current shortcut if it is a combination.
    private func registerHotKey() throws {
        guard hotKey == nil else { return }
        hotKey = try Self.register(shortcut)
    }

    /// Nil for a lone modifier, which has no hotkey. Exclusive, so a combination another app
    /// registered the same way is reported instead of silently shared.
    private static func register(_ shortcut: DictationShortcut) throws -> EventHotKeyRef? {
        guard case .combo(let keyCode, let modifiers) = shortcut else { return nil }
        let id = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers.carbonFlags, id, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            DebugLog.shared.log("Dictation key: couldn't register \(shortcut.displayName) (\(status))")
            if status == OSStatus(eventHotKeyExistsErr) { throw ShortcutError.taken("Another app already uses that shortcut.") }
            throw ShortcutError.taken("That shortcut can't be used.")
        }
        return ref
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// Carbon calls this on the main thread with our object in `userData`. A C function
    /// pointer can't capture anything, hence the static.
    private nonisolated static let hotKeyCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == DictationHotkey.hotKeySignature, id.id == DictationHotkey.hotKeyID
        else { return OSStatus(eventNotHandledErr) }
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        // Seconds since boot, the same clock as NSEvent.timestamp.
        let time = GetEventTime(event)
        let hotkey = Unmanaged<DictationHotkey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { hotkey.hotKeyEvent(pressed: pressed, at: time) }
        return noErr
    }

    private func hotKeyEvent(pressed: Bool, at time: TimeInterval) {
        guard isRunning, case .combo = shortcut else { return }
        // The combination's own modifiers are the shortcut, not a chord.
        feed(pressed ? .triggerDown : .triggerUp, at: time)
    }

    /// The macOS shortcut (Spotlight, input source switching, screenshots and so on) already on
    /// this combination, if any. Registering over one succeeds but never fires, so it has to be
    /// looked up rather than discovered by trying.
    nonisolated static func systemShortcutUsing(_ shortcut: DictationShortcut) -> String? {
        guard case .combo(let keyCode, let modifiers) = shortcut else { return nil }
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let hotKeys = array?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let clash = hotKeys.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { return false }
            return code == Int(keyCode) && UInt32(truncatingIfNeeded: flags) & relevant == modifiers.carbonFlags
        }
        return clash ? "macOS already uses that shortcut." : nil
    }

    // MARK: Missed-release safety net

    private func startReleaseTimer() {
        stopReleaseTimer()
        let timer = Timer(timeInterval: Self.releaseCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStillHeld() }
        }
        // .common so it keeps firing while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    private func stopReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    /// Turns the missed-release check off for the hold under way; the next hold has it again.
    ///
    /// For "Type as you speak". Every key event typed into the field carries no modifiers, and
    /// posting it resets what macOS reports as held, for the flags and for the key's own state
    /// alike. The check then saw the dictation key as released and ended the recording at the
    /// first typed word. The real release still arrives as a key event; if one is ever missed
    /// with the check off, pressing and releasing the shortcut again ends the recording.
    func pauseReleaseCheck() {
        stopReleaseTimer()
    }

    private func checkStillHeld() {
        guard detector.isHolding else {
            stopReleaseTimer()
            return
        }
        let held: Bool
        switch shortcut {
        case .modifier(let key):
            held = key.isDown(rawFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        case .combo(let keyCode, _):
            held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }
        guard !held else { return }
        DebugLog.shared.log("Dictation key: release was missed, treating it as released")
        // Same clock as NSEvent.timestamp: seconds since boot.
        feed(.triggerUp, at: ProcessInfo.processInfo.systemUptime)
    }
}
