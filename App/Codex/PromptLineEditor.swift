import Foundation

/// The prompt of a structured Codex session.
///
/// A structured session has no TUI of its own — the app server speaks JSON, not
/// curses — so Uncoil owns the line the user types into. This is that line:
/// pure, so the whole key matrix is testable without a PTY, and complete enough
/// to behave like a text field rather than a teletype. The previous version
/// appended bytes and knew only backspace, which meant no cursor, no word
/// motion, and — because it accepted `0x20...0x7E` and nothing else — no
/// Turkish, no accents, no emoji.
struct PromptLineEditor: Equatable {
    private(set) var text = ""
    /// Insertion point, in characters from the start of the line.
    private(set) var cursor = 0
    /// Bytes of a UTF-8 scalar seen so far, waiting for the rest of it.
    private var pendingUTF8: [UInt8] = []
    /// Bytes of an escape sequence seen so far, waiting for its final byte.
    private var pendingEscape: [UInt8] = []

    /// What the session has to act on once a batch of bytes is consumed.
    enum Action: Equatable {
        case submit(String)
        case interrupt
    }

    init(text: String = "") {
        self.text = text
        cursor = text.count
    }

    // MARK: - Input

    mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [Action]
    where Bytes.Element == UInt8 {
        var actions: [Action] = []
        for byte in bytes {
            if !pendingEscape.isEmpty {
                consumeEscape(byte)
                continue
            }
            if !pendingUTF8.isEmpty {
                consumeUTF8Continuation(byte)
                continue
            }
            switch byte {
            case 0x1B:
                pendingEscape = [byte]
            case 0x03:
                actions.append(.interrupt)
            case 0x0D, 0x0A:
                let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
                cursor = 0
                if !submitted.isEmpty { actions.append(.submit(submitted)) }
            case 0x7F, 0x08:
                deleteBackward()
            case 0x01:
                cursor = 0
            case 0x05:
                cursor = text.count
            case 0x02:
                moveLeft()
            case 0x06:
                moveRight()
            case 0x15:
                // ⌃U — and so ⌘⌫, which macOS defines as "delete to the start
                // of the line" rather than "delete everything".
                killToStart()
            case 0x0B:
                killToEnd()
            case 0x17:
                deleteWordBackward()
            case 0x00...0x1F:
                continue
            default:
                if byte < 0x80 {
                    insert(Character(UnicodeScalar(byte)))
                } else {
                    pendingUTF8 = [byte]
                }
            }
        }
        return actions
    }

    /// Adds text without treating it as typing — a dispatched prompt landing in
    /// the line, ready for the user to send.
    mutating func prefill(_ value: String) {
        for character in value {
            insert(character)
        }
    }

    // MARK: - Escape sequences

    private mutating func consumeEscape(_ byte: UInt8) {
        pendingEscape.append(byte)
        // ⎋b / ⎋f are complete in two bytes; a CSI runs until its final byte.
        if pendingEscape.count == 2 {
            switch byte {
            case 0x5B:  // '['
                return
            case 0x62:  // 'b'
                moveWordLeft()
            case 0x66:  // 'f'
                moveWordRight()
            case 0x7F, 0x08:  // ⌥⌫ arrives as ⎋⌫ on some layouts
                deleteWordBackward()
            case 0x64:  // 'd'
                deleteWordForward()
            default:
                break
            }
            pendingEscape = []
            return
        }
        // Inside a CSI: parameters first, then one final byte in @…~.
        guard (0x40...0x7E).contains(byte) else {
            // A corrupt stream must not grow the buffer without bound — but it
            // must not spill into the user's line either, so the parameters are
            // dropped while the sequence stays open until something terminates
            // it. Every letter is a terminator, so recovery costs one keystroke.
            if pendingEscape.count > 32 {
                pendingEscape = Array(pendingEscape.prefix(2))
            }
            return
        }
        let parameters = pendingEscape.dropFirst(2).dropLast()
        let isOption = parameters.split(separator: 0x3B).dropFirst().first
            .flatMap { String(decoding: $0, as: UTF8.self) } == "3"
        switch byte {
        case 0x44:  // 'D', left
            isOption ? moveWordLeft() : moveLeft()
        case 0x43:  // 'C', right
            isOption ? moveWordRight() : moveRight()
        case 0x48:  // 'H', home
            cursor = 0
        case 0x46:  // 'F', end
            cursor = text.count
        case 0x7E where parameters.first == 0x33:  // '3~', forward delete
            deleteForward()
        default:
            break
        }
        pendingEscape = []
    }

    private mutating func consumeUTF8Continuation(_ byte: UInt8) {
        pendingUTF8.append(byte)
        if let decoded = String(bytes: pendingUTF8, encoding: .utf8), let character = decoded.first {
            insert(character)
            pendingUTF8 = []
            return
        }
        // A scalar is four bytes at most; anything longer was never valid.
        if pendingUTF8.count >= 4 { pendingUTF8 = [] }
    }

    // MARK: - Editing

    private mutating func insert(_ character: Character) {
        text.insert(character, at: index(at: cursor))
        cursor += 1
    }

    private mutating func deleteBackward() {
        guard cursor > 0 else { return }
        text.remove(at: index(at: cursor - 1))
        cursor -= 1
    }

    private mutating func deleteForward() {
        guard cursor < text.count else { return }
        text.remove(at: index(at: cursor))
    }

    private mutating func killToStart() {
        guard cursor > 0 else { return }
        text.removeSubrange(text.startIndex..<index(at: cursor))
        cursor = 0
    }

    private mutating func killToEnd() {
        guard cursor < text.count else { return }
        text.removeSubrange(index(at: cursor)..<text.endIndex)
    }

    private mutating func deleteWordBackward() {
        let target = wordStart(before: cursor)
        guard target < cursor else { return }
        text.removeSubrange(index(at: target)..<index(at: cursor))
        cursor = target
    }

    private mutating func deleteWordForward() {
        let target = wordEnd(after: cursor)
        guard target > cursor else { return }
        text.removeSubrange(index(at: cursor)..<index(at: target))
    }

    private mutating func moveLeft() {
        cursor = max(0, cursor - 1)
    }

    private mutating func moveRight() {
        cursor = min(text.count, cursor + 1)
    }

    private mutating func moveWordLeft() {
        cursor = wordStart(before: cursor)
    }

    private mutating func moveWordRight() {
        cursor = wordEnd(after: cursor)
    }

    // MARK: - Words

    /// Skips whatever separates words, then the word itself — so a cursor
    /// sitting after "one two " lands before "two", not in the space.
    private func wordStart(before position: Int) -> Int {
        let characters = Array(text)
        var index = min(position, characters.count)
        while index > 0, !characters[index - 1].isWord { index -= 1 }
        while index > 0, characters[index - 1].isWord { index -= 1 }
        return index
    }

    private func wordEnd(after position: Int) -> Int {
        let characters = Array(text)
        var index = max(0, position)
        while index < characters.count, !characters[index].isWord { index += 1 }
        while index < characters.count, characters[index].isWord { index += 1 }
        return index
    }

    private func index(at offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: max(0, min(offset, text.count)))
    }
}

private extension Character {
    /// Part of a word for motion purposes: letters, digits, and the characters
    /// that hold identifiers and paths together.
    var isWord: Bool {
        isLetter || isNumber || self == "_" || self == "-" || self == "/" || self == "."
    }
}

/// Turns editor state into the escape sequence that repaints one terminal line.
enum PromptLineRenderer {
    /// Carriage return, erase the line, write it again, then park the cursor
    /// where the editor says it is. Repainting wholesale is what makes an
    /// insertion in the middle of the line come out right.
    static func render(text: String, cursor: Int) -> String {
        var output = "\r\u{001B}[2K" + text
        let trailing = max(0, text.count - max(0, min(cursor, text.count)))
        if trailing > 0 {
            output += "\u{001B}[\(trailing)D"
        }
        return output
    }
}
