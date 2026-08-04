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
    /// here. ⌥⌫ is the same story: macOS means "delete the word", which no
    /// terminal infers on its own.
    ///
    /// ⌥←/→ depends on `optionIsMeta`. With Option treated as Meta, SwiftTerm
    /// already emits ⎋b/⎋f and translating here would send them twice; with
    /// ⌘V, and nothing that merely looks like it: ⇧⌘V and ⌥⌘V are other
    /// commands in plenty of programs, and answering them as a plain paste
    /// would take them away.
    static func isPaste(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return keyCode == 9 && modifiers.intersection(relevant) == .command
    }

    /// Option left to the keyboard layout (the default, so ⌥Q can type `@`)
    /// nothing emits them, so word navigation has to come from here.
    static func editingBytes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        optionIsMeta: Bool = false
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
        case (leftArrowKeyCode, false): return optionIsMeta ? nil : Control.wordBack
        case (rightArrowKeyCode, false): return optionIsMeta ? nil : Control.wordForward
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
    /// SwiftTerm's own "Option is Meta" switch, read back so the key monitor
    /// knows whether ⌥←/→ already produce ⎋b/⎋f.
    var optionAsMetaKey: Bool { get set }
    /// Sends raw bytes to the underlying PTY.
    func sendNewline(_ bytes: [UInt8])
    /// Answers ⌘V when the clipboard holds an image, if this session and this
    /// setting say so. Returns false to let ⌘V mean what it always did.
    ///
    /// Resolved through the terminal rather than looked up in the monitor: the
    /// monitor knows which view has the keyboard and nothing else — not which
    /// session it belongs to, nor which project that session runs in.
    var handleImagePaste: () -> Bool { get }
}

/// Opts a terminal view into SwiftTerm's GPU renderer. `setUseMetal` must run
/// after the view is in a window; SwiftTerm itself handles later window moves
/// (pop-out drag) and falls back to CoreGraphics if the pipeline can't init,
/// so a throw here just means we stay on the CPU path.
///
/// Off unless asked for. Enabling it inserts an `MTKView` over the terminal and
/// hides SwiftTerm's caret view, and a session that renders but does not take
/// keystrokes is worse than a session drawn on the CPU. A renderer is an
/// optimisation; typing is the feature. Turn it on with
/// `defaults write com.gokhantopbas.uncoil TerminalMetalEnabled -bool YES`.
@MainActor
enum TerminalMetal {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "TerminalMetalEnabled")
    }

    static func enableIfPossible(_ view: TerminalView) {
        guard isEnabled, !view.isUsingMetalRenderer else { return }
        try? view.setUseMetal(true)
    }
}

/// Gives a terminal the keyboard as soon as it appears, so a freshly opened
/// session can be typed into without clicking it first.
///
/// Two things make this less trivial than `makeFirstResponder`. The view is not
/// in a window yet when SwiftUI builds it, so the call has to wait for the next
/// runloop turn; and focus is only ours to take when nobody is typing —
/// the command palette's field, a rename field or a search box owns the
/// keyboard while it is up, and yanking it away mid-word is worse than the
/// extra click this saves.
@MainActor
enum TerminalFocus {
    static func claim(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window, window.isKeyWindow else { return }
            guard !isTyping(window.firstResponder) else { return }
            guard window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    /// True when the responder is a text-entry surface. A field editor is an
    /// `NSTextView` whose delegate is the control being edited, so both the
    /// editor and the control itself have to count.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }
}

/// Daemon-backed terminal view.
final class UncoilTerminalView: TerminalView, ShiftEnterCapableTerminal {
    var resolveShiftEnterNewline: () -> Bool = { false }
    var handleImagePaste: () -> Bool = { false }
    func sendNewline(_ bytes: [UInt8]) { send(bytes) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        TerminalMetal.enableIfPossible(self)
        TerminalFocus.claim(self)
    }
}

/// In-process fallback terminal view.
final class UncoilLocalTerminalView: LocalProcessTerminalView, ShiftEnterCapableTerminal {
    var resolveShiftEnterNewline: () -> Bool = { false }
    var handleImagePaste: () -> Bool = { false }
    var onDataReceived: (Data) -> Void = { _ in }
    func sendNewline(_ bytes: [UInt8]) { send(bytes) }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onDataReceived(Data(slice))
        super.dataReceived(slice: slice)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        TerminalMetal.enableIfPossible(self)
        TerminalFocus.claim(self)
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
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                optionIsMeta: terminal.optionAsMetaKey
            ) {
                terminal.sendNewline(bytes)
                return nil  // swallow: ⌘⌫ would otherwise ring the system bell
            }
            // ⌘V with an image on the clipboard. Everything else about ⌘V —
            // text, a path, a mixed selection — is left exactly alone; the
            // decision about what "an image" means lives in
            // `ClipboardImagePaste`.
            if TerminalKeyTranslation.isPaste(
                keyCode: event.keyCode, modifiers: event.modifierFlags
            ), terminal.handleImagePaste() {
                return nil
            }
            return event
        }
    }
}
