import XCTest
@testable import Uncoil

/// Reading `theme.json` back. This is the one piece of theme logic worth
/// pinning: it runs once at launch, it is the only thing standing between an
/// upgrade and everybody's palette being silently reset, and a failure there is
/// invisible in review — the app just looks fine, wearing the wrong colours.
@MainActor
final class ThemeAppearanceTests: XCTestCase {
    private func encoded(_ value: some Encodable) -> Data {
        try! JSONEncoder().encode(value)
    }

    // MARK: - Older files

    /// theme.json used to be a bare `ThemePalette`, with no appearance in it.
    func testAFileFromAnOlderBuildKeepsItsPalette() {
        let restored = ThemeStore.restore(from: encoded(ThemePalette.light))
        XCTAssertTrue(restored.palette.isLight)
    }

    /// …and becomes an explicit choice rather than starting to follow the Mac.
    /// Someone who set the app to light and works in a dark-mode system would
    /// otherwise open it after upgrading to find it had changed on its own.
    func testAnOlderFileBecomesAnExplicitChoiceNotSystem() {
        XCTAssertEqual(ThemeStore.restore(from: encoded(ThemePalette.light)).appearance, .light)
        XCTAssertEqual(ThemeStore.restore(from: encoded(ThemePalette.dark)).appearance, .dark)
    }

    /// A custom palette from an older file survives; only its appearance is
    /// inferred.
    func testACustomisedOlderPaletteIsNotReplacedByAPreset() {
        var custom = ThemePalette.dark
        custom.highlight = 0x123456
        let restored = ThemeStore.restore(from: encoded(custom))
        XCTAssertEqual(restored.palette.highlight, 0x123456)
        XCTAssertEqual(restored.appearance, .dark)
    }

    // MARK: - Current files

    func testTheAppearanceSurvivesARoundTrip() {
        for appearance in ThemeAppearance.allCases {
            let stored = ThemeStore.Stored(palette: .dark, appearance: appearance)
            XCTAssertEqual(ThemeStore.restore(from: encoded(stored)).appearance, appearance)
        }
    }

    /// `system` is a real stored value, not the absence of one: a file that says
    /// system must not be read as "dark, chosen by hand".
    func testSystemIsStoredRatherThanInferred() {
        let stored = ThemeStore.Stored(palette: .light, appearance: .system)
        let restored = ThemeStore.restore(from: encoded(stored))
        XCTAssertEqual(restored.appearance, .system)
        XCTAssertTrue(restored.palette.isLight)
    }

    // MARK: - Nothing to read

    /// A fresh install has expressed no preference, so it follows the Mac.
    func testNoFileFollowsTheSystem() {
        XCTAssertEqual(ThemeStore.restore(from: nil).appearance, .system)
    }

    func testUnreadableContentFallsBackRatherThanCrashing() {
        let restored = ThemeStore.restore(from: Data("not json".utf8))
        XCTAssertEqual(restored.appearance, .system)
        XCTAssertFalse(restored.palette.isLight)
    }

    // MARK: - Migration

    /// A palette written before the tokens changed is replaced by the current
    /// preset *of its own mode* — never by the dark one regardless.
    func testAnOutdatedPaletteMigratesWithinItsOwnMode() {
        var stale = ThemePalette.light
        stale.version = 0
        XCTAssertTrue(ThemeStore.migrated(stale).isLight)
        XCTAssertEqual(ThemeStore.migrated(stale), ThemePalette.light)

        var current = ThemePalette.light
        current.highlight = 0xABCDEF
        XCTAssertEqual(ThemeStore.migrated(current).highlight, 0xABCDEF)
    }

    // MARK: - The choice itself

    /// The picker offers exactly three, in the order people expect to read them.
    func testThreeAppearancesAreOffered() {
        XCTAssertEqual(ThemeAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(
            ThemeAppearance.allCases.map(\.title), ["System", "Light", "Dark"]
        )
    }
}
