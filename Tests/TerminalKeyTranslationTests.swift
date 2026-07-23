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
}
