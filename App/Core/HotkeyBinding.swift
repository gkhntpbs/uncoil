import AppKit

/// A user-configurable keyboard shortcut: a virtual key code plus a canonical
/// subset of modifier flags (command / option / control / shift). Named
/// `HotkeyBinding` to avoid clashing with SwiftUI's `KeyboardShortcut`.
///
/// All matching goes through `canonicalizeModifiers(_:)`, which masks away
/// caps-lock, fn, numeric-pad and other stray flags so an event only needs the
/// four "real" modifiers to line up.
struct HotkeyBinding: Codable, Equatable {
    /// Virtual key code (`NSEvent.keyCode`), e.g. 40 = 'k'.
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` rawValue, restricted to the relevant four flags.
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = HotkeyBinding.canonicalizeModifiers(modifiers)
    }

    /// The default command-palette shortcut: ⌘K.
    static let commandPaletteDefault = HotkeyBinding(
        keyCode: 40,
        modifiers: NSEvent.ModifierFlags.command.rawValue
    )

    /// The only modifier flags we persist / compare against.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static var relevantMask: UInt { relevantModifiers.rawValue }

    /// Strips every flag except command/option/control/shift (drops caps-lock,
    /// fn, numeric-pad, help, …) so events compare on intent alone.
    static func canonicalizeModifiers(_ raw: UInt) -> UInt {
        raw & relevantMask
    }

    var canonicalModifiers: UInt { HotkeyBinding.canonicalizeModifiers(modifiers) }

    /// True when the binding carries at least one real modifier. Bare keys are
    /// rejected so the shortcut can't swallow ordinary typing.
    var hasModifier: Bool { canonicalModifiers != 0 }

    /// True when the binding cannot be confused with typing a character.
    ///
    /// Shift and Option are how a keyboard layout reaches its upper registers —
    /// ⌥Q is `@` on Turkish-Q, ⌥3 is `#` — so a hotkey built only from those
    /// silently steals a character the user has no other way to type. Command
    /// and Control never carry a layout character, so one of them is required.
    var isTextSafe: Bool {
        let flags = NSEvent.ModifierFlags(rawValue: canonicalModifiers)
        return flags.contains(.command) || flags.contains(.control)
    }

    /// Does an event (its key code + raw modifier flags) fire this binding?
    func matches(keyCode: UInt16, modifiers raw: UInt) -> Bool {
        self.keyCode == keyCode
            && HotkeyBinding.canonicalizeModifiers(raw) == canonicalModifiers
    }

    /// Readable glyph string, e.g. "⌘K", "⇧⌘K", "⌃⌥⇧⌘K". Modifiers use the
    /// macOS menu order (⌃⌥⇧⌘) followed by the key character.
    var displayString: String {
        HotkeyBinding.glyphs(forModifiers: canonicalModifiers)
            + HotkeyBinding.displayChar(forKeyCode: keyCode)
    }

    // MARK: - Pure formatting helpers

    /// Glyph run for a canonical modifier mask, in macOS menu order.
    static func glyphs(forModifiers raw: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: canonicalizeModifiers(raw))
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// Human-readable label for a virtual key code (uppercased letter, digit, or
    /// a named glyph for special keys). Falls back to a numeric placeholder.
    static func displayChar(forKeyCode keyCode: UInt16) -> String {
        if let named = specialKeyNames[keyCode] { return named }
        if let char = keyCodeChars[keyCode] { return char }
        return "⍰\(keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩",   // Return
        48: "⇥",   // Tab
        49: "␣",   // Space
        51: "⌫",   // Delete
        53: "⎋",   // Escape
        76: "⌤",   // Enter (keypad)
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let keyCodeChars: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 32: "U", 34: "I", 31: "O", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
        25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
        47: ".", 50: "`",
    ]
}
