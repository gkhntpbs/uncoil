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
            guard event.keyCode == TerminalKeyTranslation.returnKeyCode
                    || event.keyCode == TerminalKeyTranslation.keypadEnterKeyCode
            else { return event }
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
            return event
        }
    }
}
