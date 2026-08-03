import AppKit
import XCTest
@testable import Uncoil

final class TerminalKeyTranslationTests: XCTestCase {
    private let returnKey = TerminalKeyTranslation.returnKeyCode
    private let keypadEnter = TerminalKeyTranslation.keypadEnterKeyCode

    func testShiftEnterSendsBackslashCR() {
        let bytes = TerminalKeyTranslation.newlineBytes(
            keyCode: returnKey, modifiers: .shift, shiftEnterNewline: true)
        XCTAssertEqual(bytes, [0x5c, 0x0d])
    }

    func testOptionEnterSendsBackslashCR() {
        let bytes = TerminalKeyTranslation.newlineBytes(
            keyCode: returnKey, modifiers: .option, shiftEnterNewline: true)
        XCTAssertEqual(bytes, [0x5c, 0x0d])
    }

    func testKeypadEnterWithShiftSendsBackslashCR() {
        let bytes = TerminalKeyTranslation.newlineBytes(
            keyCode: keypadEnter, modifiers: .shift, shiftEnterNewline: true)
        XCTAssertEqual(bytes, [0x5c, 0x0d])
    }

    func testPlainEnterIsNotIntercepted() {
        XCTAssertNil(TerminalKeyTranslation.newlineBytes(
            keyCode: returnKey, modifiers: [], shiftEnterNewline: true))
    }

    func testShiftEnterIgnoredWhenSettingOff() {
        XCTAssertNil(TerminalKeyTranslation.newlineBytes(
            keyCode: returnKey, modifiers: .shift, shiftEnterNewline: false))
    }

    func testNonReturnKeyIsNotIntercepted() {
        // 'a' = keyCode 0, with shift held — must not be intercepted.
        XCTAssertNil(TerminalKeyTranslation.newlineBytes(
            keyCode: 0, modifiers: .shift, shiftEnterNewline: true))
    }

    func testProviderDefaults() {
        XCTAssertTrue(AgentProvider.claude.defaultShiftEnterNewline)
        XCTAssertTrue(AgentProvider.codex.defaultShiftEnterNewline)
        XCTAssertFalse(AgentProvider.terminal.defaultShiftEnterNewline)
    }

    @MainActor
    func testSettingsResolutionUsesDefaultsThenOverride() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilKeyTest-\(UUID().uuidString)")
        let settings = SettingsStore(directory: dir)

        // Defaults before any override.
        XCTAssertTrue(settings.shiftEnterNewline(for: .claude))
        XCTAssertFalse(settings.shiftEnterNewline(for: .terminal))

        // Override wins and round-trips through the map.
        settings.setShiftEnterNewline(false, for: .claude)
        XCTAssertFalse(settings.shiftEnterNewline(for: .claude))
        settings.setShiftEnterNewline(true, for: .terminal)
        XCTAssertTrue(settings.shiftEnterNewline(for: .terminal))

        try? FileManager.default.removeItem(at: dir)
    }

    /// A new terminal takes the keyboard, but never out of a field someone is
    /// typing in — the command palette and the rename fields keep it.
    @MainActor
    func testFocusIsNotClaimedFromTextEntry() {
        XCTAssertTrue(TerminalFocus.isTyping(NSTextView()))
        XCTAssertTrue(TerminalFocus.isTyping(NSTextField()))
        XCTAssertTrue(TerminalFocus.isTyping(NSSearchField()))
        XCTAssertFalse(TerminalFocus.isTyping(NSView()))
        XCTAssertFalse(TerminalFocus.isTyping(nil))
    }

    /// Option belongs to the keyboard layout unless the user says otherwise,
    /// and the choice survives a reload.
    @MainActor
    func testOptionAsMetaDefaultsOffAndRoundTrips() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilOptionMetaTest-\(UUID().uuidString)")
        let settings = SettingsStore(directory: dir)
        XCTAssertFalse(settings.optionAsMetaKey)

        settings.setOptionAsMetaKey(true)
        XCTAssertTrue(SettingsStore(directory: dir).optionAsMetaKey)

        settings.setOptionAsMetaKey(false)
        XCTAssertFalse(SettingsStore(directory: dir).optionAsMetaKey)

        try? FileManager.default.removeItem(at: dir)
    }
}
