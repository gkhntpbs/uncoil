import XCTest
@testable import Uncoil

/// The light theme's tuning, as a number rather than an opinion.
final class ThemeContrastTests: XCTestCase {
    func testTheContrastFormulaMatchesKnownValues() {
        // Black on white is the reference 21:1; a colour against itself is 1:1.
        XCTAssertEqual(ThemePalette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ThemePalette.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
        // Mid grey on white is a well-known ~4.48:1, just under the text threshold.
        XCTAssertEqual(ThemePalette.contrast(0x767676, 0xFFFFFF), 4.54, accuracy: 0.05)
    }

    func testTheLightPaletteMeetsEveryRequirement() {
        let failures = ThemePalette.light.contrastFailures
        XCTAssertTrue(
            failures.isEmpty,
            failures
                .map { "\($0.label): \(String(format: "%.2f", $0.ratio())) < \($0.minimum)" }
                .joined(separator: "\n")
        )
    }

    func testTheDarkPaletteMeetsEveryRequirement() {
        let failures = ThemePalette.dark.contrastFailures
        XCTAssertTrue(
            failures.isEmpty,
            failures
                .map { "\($0.label): \(String(format: "%.2f", $0.ratio())) < \($0.minimum)" }
                .joined(separator: "\n")
        )
    }

    func testPrimaryTextIsHeldToTheNormalTextThreshold() {
        // Uncoil's type is 9–13pt mono, so there is no large-text exemption.
        XCTAssertEqual(ThemePalette.minimumTextContrast, 4.5)
        XCTAssertGreaterThanOrEqual(
            ThemePalette.contrast(ThemePalette.light.text, ThemePalette.light.panel), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            ThemePalette.contrast(ThemePalette.dark.text, ThemePalette.dark.panel), 4.5
        )
    }

    func testEverySurfaceTextPairIsCovered() {
        let labels = Set(ThemePalette.light.contrastRequirements.map(\.label))
        for surface in ["bg", "panel", "panelHover", "panelActive"] {
            for foreground in ["text", "textDim", "textFaint", "claude", "codex"] {
                XCTAssertTrue(
                    labels.contains("\(foreground) on \(surface)"),
                    "\(foreground) on \(surface) is not being checked"
                )
            }
        }
        XCTAssertTrue(labels.contains("border on panel"))
        XCTAssertTrue(labels.contains("terminal foreground on terminal background"))
    }

    func testAnUnreadablePaletteIsCaught() {
        var broken = ThemePalette.light
        broken.textFaint = 0xF0F0F0
        XCTAssertFalse(
            broken.contrastFailures.isEmpty,
            "near-white faint text on a near-white panel must fail"
        )
    }
}
