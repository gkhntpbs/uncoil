import XCTest
@testable import Uncoil

/// `TablerIcon` draws a dot when it does not know a name, which is how the Run
/// page shipped with five capitalised names — "Refresh", "History", "Star",
/// "Pencil", "Trash" — and a row of dots where its actions should have been.
/// The font is Tabler's outline set: names are kebab-case, and no `-filled`
/// variant exists in it at all.
final class TablerIconTests: XCTestCase {
    func testTheBundledFontMapLoaded() {
        XCTAssertGreaterThan(TablerIcons.map.count, 1000)
    }

    func testEveryIconTheRunPageDrawsExists() {
        for name in [
            "player-play", "player-stop", "refresh", "history",
            "star", "file-text", "pencil", "trash",
            "radar-2", "plus", "external-link", "wand",
        ] {
            XCTAssertNotNil(TablerIcons.glyph(name), "the Run page draws '\(name)'")
        }
    }

    func testTheNamesThatUsedToDrawADotAreRejected() {
        for name in ["Refresh", "History", "Star", "Pencil", "Trash", "pinned-filled"] {
            XCTAssertNil(TablerIcons.glyph(name))
        }
    }

    /// A release build has to keep drawing the dot rather than trap in front of
    /// a user, so `reportUnknown` stays a pass-through.
    func testReportingAnUnknownNameReturnsIt() {
        XCTAssertEqual(TablerIcons.reportUnknown("no-such-icon"), "no-such-icon")
    }
}
