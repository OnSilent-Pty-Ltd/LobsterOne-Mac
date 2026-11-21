import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What starts a dictation: one modifier key held on its own, or a normal key with modifiers.
///
/// A lone modifier is watched with event monitors and never stops the key reaching the app in
/// front; a combination is registered as a system hotkey, which swallows it so it isn't also
/// typed. That split is why the two are separate cases rather than one key plus flags.
enum DictationShortcut {
    case modifier(ModifierKey)
    /// `modifiers` may be empty only for F1–F20; `problem(with:)` says so.
    case combo(keyCode: UInt16, modifiers: Modifiers)

    nonisolated static let defaultValue = DictationShortcut.modifier(.rightOption)

    /// The four modifiers a combination can carry, in the order macOS draws them: ⌃⌥⇧⌘.
    /// Fn isn't one of them; a system hotkey can't require it.
    struct Modifiers {
        let rawValue: UInt8
        nonisolated init(rawValue: UInt8) { self.rawValue = rawValue }

        nonisolated static let control = Modifiers(rawValue: 1 << 0)
        nonisolated static let option = Modifiers(rawValue: 1 << 1)
        nonisolated static let shift = Modifiers(rawValue: 1 << 2)
        nonisolated static let command = Modifiers(rawValue: 1 << 3)

        nonisolated var glyphs: String {
            var text = ""
            if contains(.control) { text += "\u{2303}" }
            if contains(.option) { text += "\u{2325}" }
            if contains(.shift) { text += "\u{21E7}" }
            if contains(.command) { text += "\u{2318}" }
            return text
        }

        /// The Carbon modifier bits `RegisterEventHotKey` wants.
        nonisolated var carbonFlags: UInt32 {
            var flags = 0
            if contains(.control) { flags |= controlKey }
            if contains(.option) { flags |= optionKey }
            if contains(.shift) { flags |= shiftKey }
            if contains(.command) { flags |= cmdKey }
            return UInt32(flags)
        }

        /// From CGEvent / NSEvent flags. Caps Lock and Fn are left out on purpose.
        nonisolated init(rawFlags: UInt64) {
            var modifiers: Modifiers = []
            if rawFlags & CGEventFlags.maskControl.rawValue != 0 { modifiers.insert(.control) }
            if rawFlags & CGEventFlags.maskAlternate.rawValue != 0 { modifiers.insert(.option) }
            if rawFlags & CGEventFlags.maskShift.rawValue != 0 { modifiers.insert(.shift) }
            if rawFlags & CGEventFlags.maskCommand.rawValue != 0 { modifiers.insert(.command) }
            self = modifiers
        }
    }

    // MARK: Saved choice

    nonisolated static let defaultsKey = "dictationShortcut"

    /// The saved shortcut. Missing or unreadable data (an older or newer build wrote something
    /// else) falls back to Right Option rather than leaving dictation with no key.
    nonisolated static var current: DictationShortcut {
        get { decode(UserDefaults.standard.data(forKey: defaultsKey)) }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    nonisolated static func decode(_ data: Data?) -> DictationShortcut {
        guard let data, let shortcut = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              problem(with: shortcut) == nil
        else { return defaultValue }
        return shortcut
    }

    // MARK: Rules

    /// Why this can't be the shortcut, or nil when it can.
    nonisolated static func problem(with shortcut: DictationShortcut) -> String? {
        guard case .combo(let keyCode, let modifiers) = shortcut else { return nil }
        // Escape is what cancels a dictation, so it can't also start one.
        if keyCode == UInt16(kVK_Escape) { return "Esc cancels dictation, so it can't start it." }
        if ModifierKey(keyCode: keyCode) != nil { return "Press a key or a combination." }
        if isFunctionKey(keyCode) { return nil }
        if modifiers.isEmpty { return "Add a modifier such as \u{2303} or \u{2325}." }
        // The hotkey swallows the combination everywhere, so Shift on its own would stop
        // capitals or symbols being typed.
        if modifiers == .shift { return "Add \u{2303}, \u{2325} or \u{2318} as well as \u{21E7}." }
        return nil
    }

    nonisolated static let functionKeys: [UInt16: Int] = [
        UInt16(kVK_F1): 1, UInt16(kVK_F2): 2, UInt16(kVK_F3): 3, UInt16(kVK_F4): 4, UInt16(kVK_F5): 5,
        UInt16(kVK_F6): 6, UInt16(kVK_F7): 7, UInt16(kVK_F8): 8, UInt16(kVK_F9): 9, UInt16(kVK_F10): 10,
        UInt16(kVK_F11): 11, UInt16(kVK_F12): 12, UInt16(kVK_F13): 13, UInt16(kVK_F14): 14, UInt16(kVK_F15): 15,
        UInt16(kVK_F16): 16, UInt16(kVK_F17): 17, UInt16(kVK_F18): 18, UInt16(kVK_F19): 19, UInt16(kVK_F20): 20,
    ]

    nonisolated static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeys[keyCode] != nil }

    // MARK: Names

    /// "Right Option (⌥)" or "⌃⌥Space". Main actor because the key's label comes from the
    /// current keyboard layout, and the input source calls want the main thread.
    @MainActor var displayName: String {
        switch self {
        case .modifier(let key): return key.displayName
        case .combo(let keyCode, let modifiers): return modifiers.glyphs + Self.keyName(keyCode)
        }
    }

    /// The opening of the toggle's subtitle.
    @MainActor var holdInstruction: String { "Hold \(displayName), speak, release." }

    /// Keys whose label isn't the character they type, or that type nothing.
    nonisolated static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete", UInt16(kVK_Escape): "Esc",
        UInt16(kVK_LeftArrow): "\u{2190}", UInt16(kVK_RightArrow): "\u{2192}",
        UInt16(kVK_DownArrow): "\u{2193}", UInt16(kVK_UpArrow): "\u{2191}",
        UInt16(kVK_Home): "Home", UInt16(kVK_End): "End", UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_Help): "Help", UInt16(kVK_ANSI_KeypadEnter): "Enter", UInt16(kVK_ANSI_KeypadClear): "Clear",
    ]

    /// Keypad keys type the same characters as the main row; saying so keeps ⌃1 and ⌃ keypad 1 apart.
    nonisolated static let keypadKeys: Set<UInt16> = [
        UInt16(kVK_ANSI_KeypadDecimal), UInt16(kVK_ANSI_KeypadMultiply), UInt16(kVK_ANSI_KeypadPlus),
        UInt16(kVK_ANSI_KeypadDivide), UInt16(kVK_ANSI_KeypadMinus), UInt16(kVK_ANSI_KeypadEquals),
        UInt16(kVK_ANSI_Keypad0), UInt16(kVK_ANSI_Keypad1), UInt16(kVK_ANSI_Keypad2), UInt16(kVK_ANSI_Keypad3),
        UInt16(kVK_ANSI_Keypad4), UInt16(kVK_ANSI_Keypad5), UInt16(kVK_ANSI_Keypad6), UInt16(kVK_ANSI_Keypad7),
        UInt16(kVK_ANSI_Keypad8), UInt16(kVK_ANSI_Keypad9),
    ]

    @MainActor static func keyName(_ keyCode: UInt16) -> String {
        if let number = functionKeys[keyCode] { return "F\(number)" }
        if let name = namedKeys[keyCode] { return name }
        guard let character = layoutCharacter(keyCode) else { return "Key \(keyCode)" }
        return keypadKeys.contains(keyCode) ? "Keypad \(character)" : character
    }

    /// What the key types with no modifiers in the current layout, upper-cased the way menus
    /// show shortcuts. Looked up rather than assumed so "Z" on AZERTY isn't shown as "W".
    @MainActor private static func layoutCharacter(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}

// Under the Xcode target's default main-actor isolation these conformances would be main-actor
// bound, and the nonisolated rules above couldn't use them. `nonisolated` conformances are
// Swift 6.2 syntax; older compilers have no default isolation, so they need nothing.
#if compiler(>=6.2)
extension DictationShortcut: nonisolated Codable, nonisolated Equatable {}
extension DictationShortcut.Modifiers: nonisolated OptionSet, nonisolated Codable, nonisolated Hashable {}
extension ModifierKey: nonisolated Codable, nonisolated CaseIterable, nonisolated Hashable {}
#else
extension DictationShortcut: Codable, Equatable {}
extension DictationShortcut.Modifiers: OptionSet, Codable, Hashable {}
extension ModifierKey: Codable, CaseIterable, Hashable {}
#endif

/// A modifier key that can be held on its own to dictate.
enum ModifierKey: String {
    case rightOption, leftOption, rightCommand, leftCommand, rightControl, leftControl, rightShift, leftShift, fn

    nonisolated init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The virtual keycode its `flagsChanged` events carry.
    nonisolated var keyCode: UInt16 {
        switch self {
        case .rightOption: UInt16(kVK_RightOption)
        case .leftOption: UInt16(kVK_Option)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .leftCommand: UInt16(kVK_Command)
        case .rightControl: UInt16(kVK_RightControl)
        case .leftControl: UInt16(kVK_Control)
        case .rightShift: UInt16(kVK_RightShift)
        case .leftShift: UInt16(kVK_Shift)
        case .fn: UInt16(kVK_Function)
        }
    }

    /// The device-independent flag, shared by the left and right key.
    nonisolated var genericFlag: UInt64 {
        switch self {
        case .rightOption, .leftOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand, .leftCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl, .leftControl: CGEventFlags.maskControl.rawValue
        case .rightShift, .leftShift: CGEventFlags.maskShift.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    // Device-dependent bits from IOKit's NX_DEVICE*KEYMASK (IOLLEvent.h). NSEvent and CGEvent
    // flags carry them in the same low bits, and they are the only way to tell right from left.
    nonisolated static let leftControlBit: UInt64 = 0x1
    nonisolated static let leftShiftBit: UInt64 = 0x2
    nonisolated static let rightShiftBit: UInt64 = 0x4
    nonisolated static let leftCommandBit: UInt64 = 0x8
    nonisolated static let rightCommandBit: UInt64 = 0x10
    nonisolated static let leftOptionBit: UInt64 = 0x20
    nonisolated static let rightOptionBit: UInt64 = 0x40
    nonisolated static let rightControlBit: UInt64 = 0x2000

    /// This key's own device bit. Fn has none; its generic flag is the only sign of it.
    nonisolated var deviceBit: UInt64 {
        switch self {
        case .rightOption: Self.rightOptionBit
        case .leftOption: Self.leftOptionBit
        case .rightCommand: Self.rightCommandBit
        case .leftCommand: Self.leftCommandBit
        case .rightControl: Self.rightControlBit
        case .leftControl: Self.leftControlBit
        case .rightShift: Self.rightShiftBit
        case .leftShift: Self.leftShiftBit
        case .fn: 0
        }
    }

    /// The same modifier on the other side of the keyboard.
    nonisolated var siblingBit: UInt64 {
        switch self {
        case .rightOption: Self.leftOptionBit
        case .leftOption: Self.rightOptionBit
        case .rightCommand: Self.leftCommandBit
        case .leftCommand: Self.rightCommandBit
        case .rightControl: Self.leftControlBit
        case .leftControl: Self.rightControlBit
        case .rightShift: Self.leftShiftBit
        case .leftShift: Self.rightShiftBit
        case .fn: 0
        }
    }

    /// This key is down. When the device bits are missing (some virtual keyboards don't set
    /// them), fall back to the generic flag.
    nonisolated func isDown(rawFlags: UInt64) -> Bool {
        guard rawFlags & genericFlag != 0 else { return false }
        if self == .fn { return true }
        let deviceBits = rawFlags & (deviceBit | siblingBit)
        return deviceBits == 0 || deviceBits & deviceBit != 0
    }

    /// Something besides this key is held: another modifier, or the same one on the other
    /// side. Caps Lock doesn't count; it stays on for long stretches and isn't a chord.
    nonisolated func hasOtherModifiers(rawFlags: UInt64) -> Bool {
        let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let others = all.rawValue & ~genericFlag
        return rawFlags & others != 0 || rawFlags & siblingBit != 0
    }

    nonisolated var displayName: String {
        switch self {
        case .rightOption: "Right Option (\u{2325})"
        case .leftOption: "Left Option (\u{2325})"
        case .rightCommand: "Right Command (\u{2318})"
        case .leftCommand: "Left Command (\u{2318})"
        case .rightControl: "Right Control (\u{2303})"
        case .leftControl: "Left Control (\u{2303})"
        case .rightShift: "Right Shift (\u{21E7})"
        case .leftShift: "Left Shift (\u{21E7})"
        case .fn: "Fn (Globe)"
        }
    }
}
