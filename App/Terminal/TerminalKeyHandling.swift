import AppKit
import SwiftTerm

/// Pure, testable translation of a physical key event into the bytes an agent
/// TUI expects. Kept free of any view/PTY state so unit tests can cover the
/// full (keyCode, modifiers, setting) → bytes matrix without a running app.
enum TerminalKeyTranslation {
    /// Virtual key codes (hardware, layout-independent).
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76

    /// Backslash + carriage return — what `claude /terminal-setup` configures
    /// terminals to send for an in-prompt newline (Claude Code / Codex TUI).
    static let newlineSequence: [UInt8] = [0x5c, 0x0d]

    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
    static let deleteKeyCode: UInt16 = 51

    /// Readline control bytes. Every agent TUI Uncoil runs — Claude Code, the
    /// Codex line editor, an ordinary shell — reads these.
    enum Control {
        /// ⌃A, start of line.
        static let lineStart: [UInt8] = [0x01]
        /// ⌃E, end of line.
        static let lineEnd: [UInt8] = [0x05]
        /// ⌃U, discard the line.
        static let killLine: [UInt8] = [0x15]
        /// ⌃W, delete the word behind the cursor.
        static let killWord: [UInt8] = [0x17]
        /// ⎋b / ⎋f, one word back or forward.
        static let wordBack: [UInt8] = [0x1B, 0x62]
        static let wordForward: [UInt8] = [0x1B, 0x66]
    }

    /// Returns the bytes to send for a Return-key event when the Shift+Enter
    /// newline behavior is enabled and Shift or Option is held; otherwise nil,
    /// meaning "let the terminal handle this key normally".
    static func newlineBytes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        shiftEnterNewline: Bool
    ) -> [UInt8]? {
        guard shiftEnterNewline else { return nil }
        guard keyCode == returnKeyCode || keyCode == keypadEnterKeyCode else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift) || flags.contains(.option) else { return nil }
        return newlineSequence
    }

    /// The macOS text-editing shortcuts a terminal does not get on its own.
    ///
    /// Command never reaches the terminal — AppKit keeps it for menus — so
    /// ⌘⌫ and ⌘←/→ do nothing at all in a prompt unless they are translated
    /// here. Option is different: SwiftTerm already sends ⎋b/⎋f for ⌥←/→ when it
    /// treats Option as Meta, so those are left alone rather than sent twice.
    /// ⌥⌫ is the exception — macOS means "delete the word", which no terminal
    /// infers on its own.
    static func editingBytes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> [UInt8]? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        // A menu shortcut is not a text edit: ⌘⌥ and ⌘⇧ combinations stay out.
        guard command != option, !flags.contains(.control) else { return nil }

        switch (keyCode, command) {
        case (deleteKeyCode, true): return Control.killLine
        case (deleteKeyCode, false): return Control.killWord
        case (leftArrowKeyCode, true): return Control.lineStart
        case (rightArrowKeyCode, true): return Control.lineEnd
        default: return nil
        }
    }
}

/// A terminal view that opts into Shift/Option+Enter → literal-newline handling.
/// SwiftTerm's `keyDown` is `public` (not `open`), so it cannot be overridden
/// from outside the module; instead a single app-wide local key monitor
/// (`TerminalKeyMonitor`) inspects the first responder and, when it is one of
/// these views, sends the newline sequence and swallows the event.
@MainActor
protocol ShiftEnterCapableTerminal: AnyObject {
    /// Resolved live from settings so a toggle change applies to open sessions.
    var resolveShiftEnterNewline: () -> Bool { get }
    /// Sends raw bytes to the underlying PTY.
    func sendNewline(_ bytes: [UInt8])
}

/// Daemon-backed terminal view.
final class UncoilTerminalView: TerminalView, ShiftEnterCapableTerminal {
    var resolveShiftEnterNewline: () -> Bool = { false }
    func sendNewline(_ bytes: [UInt8]) { send(bytes) }
}

/// In-process fallback terminal view.
final class UncoilLocalTerminalView: LocalProcessTerminalView, ShiftEnterCapableTerminal {
    var resolveShiftEnterNewline: () -> Bool = { false }
    var onDataReceived: (Data) -> Void = { _ in }
    func sendNewline(_ bytes: [UInt8]) { send(bytes) }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onDataReceived(Data(slice))
        super.dataReceived(slice: slice)
    }
}

/// Installs (once) a local key-down monitor that intercepts Return/Enter for the
/// focused Uncoil terminal and converts Shift/Option+Enter into a literal
/// newline. Non-matching events pass through untouched.
@MainActor
enum TerminalKeyMonitor {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let terminal = event.window?.firstResponder as? ShiftEnterCapableTerminal
            else { return event }

            if let bytes = TerminalKeyTranslation.newlineBytes(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                shiftEnterNewline: terminal.resolveShiftEnterNewline()
            ) {
                terminal.sendNewline(bytes)
                return nil  // swallow: don't also submit the prompt
            }
            if let bytes = TerminalKeyTranslation.editingBytes(
                keyCode: event.keyCode, modifiers: event.modifierFlags
            ) {
                terminal.sendNewline(bytes)
                return nil  // swallow: ⌘⌫ would otherwise ring the system bell
            }
            return event
        }
    }
}
