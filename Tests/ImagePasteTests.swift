import AppKit
import XCTest
@testable import Uncoil

/// Answering ⌘V is taking a key away from the terminal underneath, so the
/// question that matters is not "can we paste an image" but "when must we not".
final class ClipboardImagePasteTests: XCTestCase {
    // MARK: - What is taken

    func testAnImageOnTheClipboardIsTaken() {
        XCTAssertTrue(
            ClipboardImagePaste.shouldIntercept(types: [.png], mode: .attachFile)
        )
        XCTAssertTrue(
            ClipboardImagePaste.shouldIntercept(types: [.tiff], mode: .attachFile)
        )
    }

    /// The whole point of the setting: an agent that reads pasted images well
    /// should keep doing it.
    func testNothingIsTakenWhenTheAgentIsMeantToHandleIt() {
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(types: [.png], mode: .agent)
        )
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(fileNames: ["a.png"], mode: .agent)
        )
    }

    // MARK: - What is left alone

    func testPastingTextIsNeverTouched() {
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(types: [.string], mode: .attachFile)
        )
    }

    /// A clipboard carries several representations at once: copying from a
    /// browser can put an image beside the HTML, and copying a file in the
    /// Finder puts a name beside the URL. Taking any clipboard that merely
    /// mentions an image would break pasting a path or a sentence into a
    /// prompt — which is most of what ⌘V is for.
    func testAClipboardThatAlsoCarriesTextIsLeftToTheTerminal() {
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(types: [.png, .string], mode: .attachFile)
        )
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(types: [.string, .tiff], mode: .attachFile)
        )
    }

    func testAnEmptyClipboardIsNotOurs() {
        XCTAssertFalse(ClipboardImagePaste.shouldIntercept(types: [], mode: .attachFile))
        XCTAssertFalse(ClipboardImagePaste.shouldIntercept(fileNames: [], mode: .attachFile))
    }

    // MARK: - Copied files

    func testCopiedImageFilesAreTaken() {
        XCTAssertTrue(
            ClipboardImagePaste.shouldIntercept(
                fileNames: ["shot.png", "diagram.jpg"], mode: .attachFile
            )
        )
    }

    /// All or nothing: attaching some of a mixed selection and silently
    /// dropping the rest is worse than attaching none of it.
    func testAMixedSelectionOfFilesIsNotTaken() {
        XCTAssertFalse(
            ClipboardImagePaste.shouldIntercept(
                fileNames: ["shot.png", "notes.md"], mode: .attachFile
            )
        )
    }

    // MARK: - The default

    /// An agent's own paste is better when it works. A paste that silently does
    /// nothing is worse than a path, so the reliable route is the default and
    /// the other is one setting away.
    func testTheDefaultIsTheOneThatAlwaysWorks() {
        XCTAssertEqual(ImagePasteMode.default, .attachFile)
    }

    func testBothModesSayWhatTheyDo() {
        for mode in ImagePasteMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.detail.isEmpty, mode.rawValue)
        }
    }
}

/// ⌘V has to be recognised without swallowing the commands that look like it.
final class PasteKeyTests: XCTestCase {
    private let vKeyCode: UInt16 = 9

    func testPlainCommandVIsAPaste() {
        XCTAssertTrue(
            TerminalKeyTranslation.isPaste(keyCode: vKeyCode, modifiers: .command)
        )
    }

    /// ⇧⌘V and ⌥⌘V are other commands in plenty of programs — "paste and match
    /// style" among them — and answering them as a plain paste takes them away.
    func testTheOtherPasteShortcutsAreNotTouched() {
        XCTAssertFalse(
            TerminalKeyTranslation.isPaste(keyCode: vKeyCode, modifiers: [.command, .shift])
        )
        XCTAssertFalse(
            TerminalKeyTranslation.isPaste(keyCode: vKeyCode, modifiers: [.command, .option])
        )
        XCTAssertFalse(
            TerminalKeyTranslation.isPaste(keyCode: vKeyCode, modifiers: [.command, .control])
        )
    }

    func testTypingAVIsNotAPaste() {
        XCTAssertFalse(TerminalKeyTranslation.isPaste(keyCode: vKeyCode, modifiers: []))
    }

    /// A modifier the shortcut does not care about must not stop it: caps lock
    /// and the numeric-keypad flag ride along on ordinary events.
    func testAnIrrelevantModifierDoesNotBreakIt() {
        XCTAssertTrue(
            TerminalKeyTranslation.isPaste(
                keyCode: vKeyCode, modifiers: [.command, .capsLock]
            )
        )
    }

    func testAnotherKeyWithCommandIsNotAPaste() {
        XCTAssertFalse(TerminalKeyTranslation.isPaste(keyCode: 8, modifiers: .command))
    }
}
