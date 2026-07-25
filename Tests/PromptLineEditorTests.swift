import AppKit
import XCTest
@testable import Uncoil

/// The prompt of a structured Codex session. It has to behave like a text field,
/// not a teletype: a cursor that moves by word, deletes that respect it, and any
/// character a keyboard can produce — the previous editor accepted `0x20...0x7E`
/// and silently dropped every Turkish letter.
final class PromptLineEditorTests: XCTestCase {
    private func editor(_ text: String = "") -> PromptLineEditor {
        PromptLineEditor(text: text)
    }

    private func type(_ string: String, into editor: inout PromptLineEditor) -> [PromptLineEditor.Action] {
        editor.consume(Array(string.utf8))
    }

    // MARK: - Typing

    func testTypingAsciiAppendsAndMovesTheCursor() {
        var editor = self.editor()
        _ = type("merhaba", into: &editor)
        XCTAssertEqual(editor.text, "merhaba")
        XCTAssertEqual(editor.cursor, 7)
    }

    func testTurkishLettersSurviveInsteadOfBeingDropped() {
        var editor = self.editor()
        _ = type("şğıöüç İĞ", into: &editor)
        XCTAssertEqual(editor.text, "şğıöüç İĞ")
        XCTAssertEqual(editor.cursor, 9)
    }

    func testAMultiByteScalarSplitAcrossTwoWritesStillArrives() {
        var editor = self.editor()
        let bytes = Array("ş".utf8)
        _ = editor.consume([bytes[0]])
        XCTAssertEqual(editor.text, "", "Half a character must not be shown")
        _ = editor.consume([bytes[1]])
        XCTAssertEqual(editor.text, "ş")
    }

    func testEmojiCountsAsOneCharacter() {
        var editor = self.editor()
        _ = type("🎯", into: &editor)
        XCTAssertEqual(editor.text, "🎯")
        XCTAssertEqual(editor.cursor, 1)
    }

    // MARK: - Submitting

    func testReturnSubmitsAndClearsTheLine() {
        var editor = self.editor("bir görev")
        let actions = editor.consume([0x0D])
        XCTAssertEqual(actions, [.submit("bir görev")])
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.cursor, 0)
    }

    func testAnEmptyLineSubmitsNothing() {
        var editor = self.editor("   ")
        XCTAssertEqual(editor.consume([0x0D]), [])
    }

    func testControlCInterrupts() {
        var editor = self.editor("yarım kalan")
        XCTAssertEqual(editor.consume([0x03]), [.interrupt])
        XCTAssertEqual(editor.text, "yarım kalan", "An interrupt is not an erase")
    }

    // MARK: - Cursor motion

    func testArrowKeysMoveOneCharacter() {
        var editor = self.editor("abc")
        _ = editor.consume(Array("\u{1B}[D".utf8))
        XCTAssertEqual(editor.cursor, 2)
        _ = editor.consume(Array("\u{1B}[C".utf8))
        XCTAssertEqual(editor.cursor, 3)
    }

    func testInsertingInTheMiddleGoesWhereTheCursorIs() {
        var editor = self.editor("ac")
        _ = editor.consume(Array("\u{1B}[D".utf8))
        _ = type("b", into: &editor)
        XCTAssertEqual(editor.text, "abc")
        XCTAssertEqual(editor.cursor, 2)
    }

    /// ⌥← / ⌥→ as SwiftTerm sends them when Option is Meta.
    func testOptionArrowsMoveByWord() {
        var editor = self.editor("git commit --amend")
        _ = editor.consume(Array("\u{1B}b".utf8))
        XCTAssertEqual(editor.cursor, 11, "Should land at the start of \"--amend\"")
        _ = editor.consume(Array("\u{1B}b".utf8))
        XCTAssertEqual(editor.cursor, 4)
        _ = editor.consume(Array("\u{1B}f".utf8))
        XCTAssertEqual(editor.cursor, 10)
    }

    /// The other encoding of ⌥←/→, which terminals in kitty/xterm modes emit.
    func testCsiModifierArrowsAlsoMoveByWord() {
        var editor = self.editor("bir iki")
        _ = editor.consume(Array("\u{1B}[1;3D".utf8))
        XCTAssertEqual(editor.cursor, 4)
        _ = editor.consume(Array("\u{1B}[1;3C".utf8))
        XCTAssertEqual(editor.cursor, 7)
    }

    func testHomeAndEndJumpToTheEdges() {
        var editor = self.editor("abcdef")
        _ = editor.consume([0x01])
        XCTAssertEqual(editor.cursor, 0)
        _ = editor.consume([0x05])
        XCTAssertEqual(editor.cursor, 6)
        _ = editor.consume(Array("\u{1B}[H".utf8))
        XCTAssertEqual(editor.cursor, 0)
        _ = editor.consume(Array("\u{1B}[F".utf8))
        XCTAssertEqual(editor.cursor, 6)
    }

    func testMotionStopsAtTheEnds() {
        var editor = self.editor("ab")
        _ = editor.consume(Array("\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D".utf8))
        XCTAssertEqual(editor.cursor, 0)
        _ = editor.consume(Array("\u{1B}[C\u{1B}[C\u{1B}[C".utf8))
        XCTAssertEqual(editor.cursor, 2)
    }

    // MARK: - Deleting

    func testBackspaceDeletesBeforeTheCursorOnly() {
        var editor = self.editor("abc")
        _ = editor.consume(Array("\u{1B}[D".utf8))
        _ = editor.consume([0x7F])
        XCTAssertEqual(editor.text, "ac")
        XCTAssertEqual(editor.cursor, 1)
    }

    func testBackspaceOnAnEmptyLineIsHarmless() {
        var editor = self.editor()
        _ = editor.consume([0x7F, 0x7F])
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.cursor, 0)
    }

    /// ⌥⌫ — delete the word behind the cursor.
    func testDeleteWordBackwardTakesTheWholeWord() {
        var editor = self.editor("git commit --amend")
        _ = editor.consume([0x17])
        XCTAssertEqual(editor.text, "git commit ")
        _ = editor.consume([0x17])
        XCTAssertEqual(editor.text, "git ")
    }

    /// ⌘⌫ — macOS deletes from the cursor to the start of the line, so with the
    /// cursor at the end the line goes away.
    func testCommandBackspaceKillsToTheStartOfTheLine() {
        var editor = self.editor("silinecek satır")
        _ = editor.consume([0x15])
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.cursor, 0)
    }

    func testKillToStartKeepsWhatIsAfterTheCursor() {
        var editor = self.editor("baş son")
        _ = editor.consume(Array("\u{1B}b".utf8))  // before "son"
        _ = editor.consume([0x15])
        XCTAssertEqual(editor.text, "son")
        XCTAssertEqual(editor.cursor, 0)
    }

    func testForwardDeleteRemovesUnderTheCursor() {
        var editor = self.editor("abc")
        _ = editor.consume([0x01])
        _ = editor.consume(Array("\u{1B}[3~".utf8))
        XCTAssertEqual(editor.text, "bc")
    }

    // MARK: - Robustness

    func testAnUnknownEscapeSequenceIsIgnoredRatherThanTyped() {
        var editor = self.editor("x")
        _ = editor.consume(Array("\u{1B}[200~".utf8))
        XCTAssertEqual(editor.text, "x")
    }

    /// A corrupt stream must neither grow a buffer without bound nor spill its
    /// parameter bytes into the line as if they had been typed. The sequence
    /// stays open until something terminates it, and any letter terminates it —
    /// so recovery costs one keystroke, not a stuck prompt.
    func testAnUnterminatedEscapeSequenceNeitherGrowsNorLeaksIntoTheLine() {
        var editor = self.editor()
        _ = editor.consume([0x1B, 0x5B] + Array(repeating: UInt8(0x31), count: 200))
        _ = type("D", into: &editor)  // terminates the sequence
        XCTAssertEqual(editor.text, "", "Escape parameters were typed into the prompt")
        _ = type("a", into: &editor)
        XCTAssertEqual(editor.text, "a", "The editor stayed stuck inside an escape sequence")
    }

    func testAPrefilledPromptLandsInTheLineWithoutSubmitting() {
        var editor = self.editor()
        editor.prefill("hazır görev")
        XCTAssertEqual(editor.text, "hazır görev")
        XCTAssertEqual(editor.cursor, 11)
    }

    // MARK: - Rendering

    func testRenderRepaintsTheLineAndParksTheCursor() {
        XCTAssertEqual(
            PromptLineRenderer.render(text: "abc", cursor: 3),
            "\r\u{001B}[2Kabc"
        )
        XCTAssertEqual(
            PromptLineRenderer.render(text: "abc", cursor: 1),
            "\r\u{001B}[2Kabc\u{001B}[2D"
        )
    }

    func testRenderClampsACursorOutsideTheText() {
        XCTAssertEqual(PromptLineRenderer.render(text: "ab", cursor: 99), "\r\u{001B}[2Kab")
    }
}

/// ⌘ never reaches a terminal — AppKit keeps it for menus — so the macOS editing
/// shortcuts have to be translated into the control bytes a prompt understands.
final class TerminalEditingKeyTests: XCTestCase {
    private let left = TerminalKeyTranslation.leftArrowKeyCode
    private let right = TerminalKeyTranslation.rightArrowKeyCode
    private let delete = TerminalKeyTranslation.deleteKeyCode

    func testCommandBackspaceDiscardsTheLine() {
        XCTAssertEqual(
            TerminalKeyTranslation.editingBytes(keyCode: delete, modifiers: [.command]),
            TerminalKeyTranslation.Control.killLine
        )
    }

    func testOptionBackspaceDeletesAWord() {
        XCTAssertEqual(
            TerminalKeyTranslation.editingBytes(keyCode: delete, modifiers: [.option]),
            TerminalKeyTranslation.Control.killWord
        )
    }

    func testCommandArrowsJumpToTheLineEdges() {
        XCTAssertEqual(
            TerminalKeyTranslation.editingBytes(keyCode: left, modifiers: [.command]),
            TerminalKeyTranslation.Control.lineStart
        )
        XCTAssertEqual(
            TerminalKeyTranslation.editingBytes(keyCode: right, modifiers: [.command]),
            TerminalKeyTranslation.Control.lineEnd
        )
    }

    /// SwiftTerm already sends ⎋b/⎋f for ⌥←/→; translating them here as well
    /// would move two words per press.
    func testOptionArrowsAreLeftToSwiftTerm() {
        XCTAssertNil(TerminalKeyTranslation.editingBytes(keyCode: left, modifiers: [.option]))
        XCTAssertNil(TerminalKeyTranslation.editingBytes(keyCode: right, modifiers: [.option]))
    }

    func testAPlainKeyIsNotTouched() {
        XCTAssertNil(TerminalKeyTranslation.editingBytes(keyCode: delete, modifiers: []))
        XCTAssertNil(TerminalKeyTranslation.editingBytes(keyCode: left, modifiers: []))
    }

    /// A menu shortcut is not a text edit.
    func testCombinationsThatBelongToMenusArePassedThrough() {
        XCTAssertNil(
            TerminalKeyTranslation.editingBytes(keyCode: delete, modifiers: [.command, .option])
        )
        XCTAssertNil(
            TerminalKeyTranslation.editingBytes(keyCode: left, modifiers: [.command, .control])
        )
    }

    /// The bytes have to be the ones a prompt actually reads.
    func testTheControlBytesAreTheReadlineOnes() {
        XCTAssertEqual(TerminalKeyTranslation.Control.killLine, [0x15])
        XCTAssertEqual(TerminalKeyTranslation.Control.killWord, [0x17])
        XCTAssertEqual(TerminalKeyTranslation.Control.lineStart, [0x01])
        XCTAssertEqual(TerminalKeyTranslation.Control.lineEnd, [0x05])
        XCTAssertEqual(TerminalKeyTranslation.Control.wordBack, [0x1B, 0x62])
        XCTAssertEqual(TerminalKeyTranslation.Control.wordForward, [0x1B, 0x66])
    }
}

/// The editor is what ⌘⌫ and ⌥← end up talking to in a structured session, so
/// the two halves are checked together: the key produces bytes, the bytes edit
/// the line.
final class TerminalKeyToPromptTests: XCTestCase {
    private func send(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        to editor: inout PromptLineEditor
    ) {
        guard let bytes = TerminalKeyTranslation.editingBytes(
            keyCode: keyCode, modifiers: modifiers
        ) else { return }
        _ = editor.consume(bytes)
    }

    func testCommandBackspaceClearsThePrompt() {
        var editor = PromptLineEditor(text: "uzun bir komut")
        send(keyCode: TerminalKeyTranslation.deleteKeyCode, modifiers: [.command], to: &editor)
        XCTAssertEqual(editor.text, "")
    }

    func testOptionBackspaceRemovesTheLastWordOfThePrompt() {
        var editor = PromptLineEditor(text: "uzun bir komut")
        send(keyCode: TerminalKeyTranslation.deleteKeyCode, modifiers: [.option], to: &editor)
        XCTAssertEqual(editor.text, "uzun bir ")
    }

    func testCommandLeftThenTypingInsertsAtTheStart() {
        var editor = PromptLineEditor(text: "komut")
        send(keyCode: TerminalKeyTranslation.leftArrowKeyCode, modifiers: [.command], to: &editor)
        _ = editor.consume(Array("!".utf8))
        XCTAssertEqual(editor.text, "!komut")
    }
}
