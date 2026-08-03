import XCTest
@testable import Uncoil

/// A dozen agents working at once made the sidebar flicker, so the pulse became
/// tunable. What must not change with the tuning is the *signal*: an attention
/// row is still marked in its status's colour at every level.
final class AttentionEmphasisTests: XCTestCase {
    func testOnlyOffStopsTheMotion() {
        XCTAssertFalse(AttentionEmphasis.off.animates)
        XCTAssertTrue(AttentionEmphasis.subtle.animates)
        XCTAssertTrue(AttentionEmphasis.full.animates)
    }

    func testEveryLevelStillMarksTheRow() {
        for emphasis in AttentionEmphasis.allCases {
            XCTAssertGreaterThan(
                emphasis.borderRange.low, 0,
                "\(emphasis.rawValue) leaves an attention row unmarked"
            )
        }
    }

    /// "Off" is one steady value, not a pulse with the ends set equal by luck.
    func testOffHasNoRangeToBreatheAcross() {
        let range = AttentionEmphasis.off.borderRange
        XCTAssertEqual(range.low, range.high)
        XCTAssertEqual(AttentionEmphasis.off.fillOpacity, 0)
        XCTAssertEqual(AttentionEmphasis.off.period, 0)
    }

    /// Subtle is the default, and it has to actually be subtler than full —
    /// shallower and slower — or the setting is decoration.
    func testSubtleIsQuieterAndSlowerThanFull() {
        let subtle = AttentionEmphasis.subtle
        let full = AttentionEmphasis.full
        XCTAssertLessThan(subtle.fillOpacity, full.fillOpacity)
        XCTAssertLessThan(
            subtle.borderRange.high - subtle.borderRange.low,
            full.borderRange.high - full.borderRange.low
        )
        XCTAssertGreaterThan(subtle.period, full.period)
    }

    @MainActor
    func testTheDefaultIsSubtleAndTheChoiceRoundTrips() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilAttentionTest-\(UUID().uuidString)")
        let settings = SettingsStore(directory: dir)
        XCTAssertEqual(settings.attentionEmphasis, .subtle)
        XCTAssertEqual(AttentionMotion.shared.emphasis, .subtle)

        settings.setAttentionEmphasis(.off)
        XCTAssertEqual(AttentionMotion.shared.emphasis, .off)
        XCTAssertEqual(SettingsStore(directory: dir).attentionEmphasis, .off)

        settings.setAttentionEmphasis(.subtle)
        try? FileManager.default.removeItem(at: dir)
    }
}
