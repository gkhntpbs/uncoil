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
    /// The longest a title can be before the sidebar truncates it anyway.
    static let maxLength = 42

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
        return firstLine.count > maxLength
            ? String(firstLine.prefix(maxLength - 1)) + "…"
            : firstLine
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
            /// Inside a CSI or SS3 sequence, waiting for its final byte.
            case parameters
        }

        private var bytes: [UInt8] = []
        private var escape: EscapeState = .none
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
                escape = (byte == 0x5B || byte == 0x4F) ? .parameters : .none
                return nil
            case .parameters:
                if (0x40...0x7E).contains(byte) { escape = .none }
                return nil
            }
            switch byte {
            case 0x1B:
                escape = .introducer
            case 0x0D, 0x0A:
                defer { reset() }
                guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
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
