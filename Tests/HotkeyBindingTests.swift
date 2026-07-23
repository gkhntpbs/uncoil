import XCTest
import AppKit
@testable import Uncoil

final class HotkeyBindingTests: XCTestCase {
    private let cmd = NSEvent.ModifierFlags.command.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue
    private let option = NSEvent.ModifierFlags.option.rawValue
    private let control = NSEvent.ModifierFlags.control.rawValue
    private let capsLock = NSEvent.ModifierFlags.capsLock.rawValue
    private let fn = NSEvent.ModifierFlags.function.rawValue

    func testDefaultIsCommandK() {
        let d = HotkeyBinding.commandPaletteDefault
        XCTAssertEqual(d.keyCode, 40)
        XCTAssertEqual(d.modifiers, cmd)
        XCTAssertEqual(d.displayString, "⌘K")
        XCTAssertTrue(d.hasModifier)
    }

    func testMatchesCommandK() {
        let d = HotkeyBinding.commandPaletteDefault
        XCTAssertTrue(d.matches(keyCode: 40, modifiers: cmd))
    }

    func testDoesNotMatchCommandShiftK() {
        let d = HotkeyBinding.commandPaletteDefault
        XCTAssertFalse(d.matches(keyCode: 40, modifiers: cmd | shift))
    }

    func testDoesNotMatchBareK() {
        let d = HotkeyBinding.commandPaletteDefault
        XCTAssertFalse(d.matches(keyCode: 40, modifiers: 0))
    }

    func testMatchIgnoresCapsLockAndFn() {
        let d = HotkeyBinding.commandPaletteDefault
        XCTAssertTrue(d.matches(keyCode: 40, modifiers: cmd | capsLock | fn))
    }

    func testCanonicalizeStripsIrrelevantFlags() {
        let raw = cmd | shift | capsLock | fn
        XCTAssertEqual(HotkeyBinding.canonicalizeModifiers(raw), cmd | shift)
    }

    func testInitCanonicalizesStoredModifiers() {
        let b = HotkeyBinding(keyCode: 40, modifiers: cmd | capsLock)
        XCTAssertEqual(b.modifiers, cmd)
    }

    func testHasModifierFalseForBare() {
        let b = HotkeyBinding(keyCode: 40, modifiers: capsLock | fn)
        XCTAssertFalse(b.hasModifier)
    }

    func testGlyphOrderIsMenuStyle() {
        let all = HotkeyBinding(keyCode: 40, modifiers: cmd | option | control | shift)
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘K")
        let cs = HotkeyBinding(keyCode: 40, modifiers: cmd | shift)
        XCTAssertEqual(cs.displayString, "⇧⌘K")
    }

    func testDisplayCharVariety() {
        XCTAssertEqual(HotkeyBinding.displayChar(forKeyCode: 40), "K")
        XCTAssertEqual(HotkeyBinding.displayChar(forKeyCode: 49), "␣")   // Space
        XCTAssertEqual(HotkeyBinding.displayChar(forKeyCode: 18), "1")
        XCTAssertEqual(HotkeyBinding.displayChar(forKeyCode: 53), "⎋")   // Escape
        XCTAssertEqual(HotkeyBinding(keyCode: 3, modifiers: cmd).displayString, "⌘F")
    }

    func testBackwardCompatDecodeWithoutField() throws {
        // Simulate settings.json written before the hotkey field existed: encode
        // a default Persisted (nil hotkey ⇒ key omitted), strip nothing, decode.
        // The optional field must decode as nil so the store falls back to ⌘K.
        let data = try JSONEncoder().encode(SettingsStore.Persisted())
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(object["commandPaletteHotkey"])

        let persisted = try JSONDecoder().decode(SettingsStore.Persisted.self, from: data)
        XCTAssertNil(persisted.commandPaletteHotkey)
    }

    func testRoundTripEncodeDecode() throws {
        let original = HotkeyBinding(keyCode: 3, modifiers: cmd | shift)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
