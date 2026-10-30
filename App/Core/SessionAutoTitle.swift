import Foundation

/// Names a session after the first thing its user asked it to do.
///
/// A sidebar full of "claude: new session" tells nobody which session is
/// which, and Uncoil already knows the one sentence that does: the first
/// prompt. The name is taken locally, from text the app can already see — no
/// model is asked, so it costs no quota, needs no login, and is the same on
/// every run.
///
/// It happens exactly once. A session keeps the name it was given, because a
/// row whose label changes while it is being read is the same defect as a row
/// that moves while it is being clicked.
enum SessionAutoTitle {
    /// The first line of a prompt, tightened for the sidebar — or nil when
    /// there is nothing in it worth showing.
    ///
    /// Slash commands keep their name: `/release 0.2.0` says more about the
    /// session than the first line of a paragraph often does.
    static func candidate(from prompt: String) -> String? {
        let firstLine = prompt
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return nil }
        return firstLine
    }

    /// Whether a title is a terminal's reply to a colour query rather than
    /// anything a person typed — `10;rgb:e9e9/e9e9/ecec11;rgb:0f0f/…`.
    ///
    /// Earlier builds read those replies as keystrokes and named sessions
    /// after them; a title like that is put back to the placeholder so the
    /// next real prompt can name the session properly.
    static func isTerminalReply(_ title: String) -> Bool {
        title.range(of: #"^\d+;rgb:[0-9a-fA-F]+/"#, options: .regularExpression) != nil
    }

    /// Collects the bytes a user types into a terminal until they press
    /// Return, so a session can be named after a prompt nobody submitted
    /// through the app.
    ///
    /// Only the providers that report their prompts through hooks are visible
    /// any other way; everything else — Codex's TUI, Gemini, a plain shell —
    /// goes straight from the keyboard to the PTY, and this is the only place
    /// the app sees it at all.
    ///
    /// Bytes rather than characters, because that is what arrives: a typed
    /// `ş` is two of them and a pressed arrow key is three that must not end
    /// up in a title.
    struct TypedLineBuffer {
        /// Past this a line is not a title by any reading, and holding more of
        /// it only serves a paste nobody will name a session after.
        static let byteLimit = 4096

        private enum EscapeState {
            /// Nothing pending: the next byte is text.
            case none
            /// ESC seen; the byte after it says whether more follow.
            case introducer
            /// Inside a CSI sequence, collecting it until its final byte.
            case csi
            /// After ESC O: exactly one more byte.
            case ss3
            /// Inside an OSC, DCS, APC, PM or SOS string, which runs to BEL
            /// or to ESC \.
            case string
            /// ESC seen inside such a string — the start of its terminator.
            case stringEscape
        }

        private var bytes: [UInt8] = []
        private var escape: EscapeState = .none
        private var sequence: [UInt8] = []
        private var isOverflowing = false

        init() {}

        /// Feeds keystrokes; returns the completed line when Return is pressed.
        mutating func feed(_ data: some Sequence<UInt8>) -> String? {
            var completed: String?
            for byte in data {
                if let line = accept(byte) { completed = line }
            }
            return completed
        }

        private mutating func accept(_ byte: UInt8) -> String? {
            switch escape {
            case .none:
                break
            case .introducer:
                // An arrow key is ESC [ A; ESC c is the whole sequence. What
                // follows the ESC is what says which of the two this is.
                switch byte {
                case 0x5B: escape = .csi; sequence.removeAll()
                case 0x4F: escape = .ss3
                // The terminal's own answers travel this way too: asked for
                // its colours (OSC 10/11), SwiftTerm replies down the same
                // pipe the keys go, and reading that reply as typing is what
                // named Codex sessions `10;rgb:e9e9/e9e9/ecec…`.
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: escape = .string
                default: escape = .none
                }
                return nil
            case .ss3:
                escape = .none
                return nil
            case .csi:
                if (0x40...0x7E).contains(byte) {
                    escape = .none
                    if byte == 0x75 { acceptKittyKey(sequence) }
                } else if sequence.count < 64 {
                    sequence.append(byte)
                }
                return nil
            case .string:
                if byte == 0x07 { escape = .none } else if byte == 0x1B { escape = .stringEscape }
                return nil
            case .stringEscape:
                escape = byte == 0x5C ? .none : .string
                return nil
            }
            switch byte {
            case 0x1B:
                escape = .introducer
            case 0x0D, 0x0A:
                defer { reset() }
                guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
                // A bare `/model` or `/status` operates the agent's own screen;
                // it is not what the session is for. One with arguments still
                // names it — `/release 0.2.0` says plenty.
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/"), !trimmed.contains(" ") { return nil }
                return candidate(from: text)
            case 0x08, 0x7F:
                removeLastCharacter()
            case 0x03, 0x15:
                // Ctrl-C abandons the line; Ctrl-U erases it. Either way what
                // was typed was never asked.
                reset()
            case ..<0x20:
                break
            default:
                guard bytes.count < Self.byteLimit else {
                    isOverflowing = true
                    break
                }
                bytes.append(byte)
            }
            return nil
        }

        /// A key sent in the kitty keyboard protocol, `CSI code[:shifted];mods[:event] u`.
        ///
        /// Codex turns that protocol on, and with it every shifted key arrives
        /// this way rather than as the character — on a Turkish layout that is
        /// every capital and `/` itself, which is how `/model` became "model".
        private mutating func acceptKittyKey(_ parameters: [UInt8]) {
            let fields = String(decoding: parameters, as: UTF8.self)
                .split(separator: ";", omittingEmptySubsequences: false)
            guard let keyField = fields.first else { return }
            let keys = keyField.split(separator: ":", omittingEmptySubsequences: false)
            guard let code = keys.first.flatMap({ UInt32($0) }) else { return }
            let shifted = keys.count > 1 ? UInt32(keys[1]) : nil
            let modifierParts = fields.count > 1
                ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
            let modifiers = (modifierParts.first.flatMap { Int($0) } ?? 1) - 1
            let event = modifierParts.count > 1 ? Int(modifierParts[1]) ?? 1 : 1
            // Releases carry nothing new, and repeats only matter for text.
            guard event != 3 else { return }
            let shift = modifiers & 1 != 0
            let capsLock = modifiers & 64 != 0
            let commandLike = modifiers & (2 | 4 | 8) != 0
            if commandLike {
                // Ctrl-C and Ctrl-U, disambiguated: the same abandonment as
                // their legacy bytes.
                if modifiers & 4 != 0, code == 0x63 || code == 0x75 { reset() }
                return
            }
            switch code {
            case 0x08, 0x7F:
                removeLastCharacter()
                return
            case ..<0x20:
                return
            default:
                break
            }
            if fields.count > 2 {
                // The terminal said which text the key produced; nothing to infer.
                for value in fields[2].split(separator: ":") {
                    if let scalar = UInt32(value).flatMap(Unicode.Scalar.init) { append(scalar) }
                }
                return
            }
            // Private-use codes are keys with no text: arrows, F-keys, keypad.
            guard !(0xE000...0xF8FF).contains(code),
                  let base = Unicode.Scalar(code) else { return }
            if shift, let shifted, let scalar = Unicode.Scalar(shifted) {
                append(scalar)
            } else if shift || capsLock {
                for scalar in String(base).uppercased().unicodeScalars { append(scalar) }
            } else {
                append(base)
            }
        }

        private mutating func append(_ scalar: Unicode.Scalar) {
            for byte in String(scalar).utf8 {
                guard bytes.count < Self.byteLimit else {
                    isOverflowing = true
                    return
                }
                bytes.append(byte)
            }
        }

        /// Drops one character, not one byte: a continuation byte left behind
        /// would make the whole line undecodable.
        private mutating func removeLastCharacter() {
            guard !isOverflowing else { return }
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
            if !bytes.isEmpty { bytes.removeLast() }
        }

        private mutating func reset() {
            bytes.removeAll(keepingCapacity: false)
            isOverflowing = false
        }
    }
}
