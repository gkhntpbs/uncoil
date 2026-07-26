import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// The header chip's size, asserted rather than eyeballed: the first version
/// took a flexible width and stretched across the whole header, and it stood a
/// different height from the controls beside it.
@MainActor
final class BranchBadgeLayoutTests: XCTestCase {
    private func size(of view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        return host.fittingSize
    }

    func testBadgeIsAsTallAsTheControlBlocksBesideIt() {
        // 22pt of content in a 3pt inset — the editor control's box.
        XCTAssertEqual(size(of: BranchBadge(branch: "main")).height, 28, accuracy: 0.5)
    }

    func testBadgeHugsItsTextInsteadOfFillingTheRow() {
        let narrow = size(of: BranchBadge(branch: "main")).width
        XCTAssertLessThan(narrow, 110, "a four-letter branch must not need a wide chip")

        // Offered a whole header's worth of room, it must not take it.
        let inRow = size(of: HStack { Spacer(); BranchBadge(branch: "main") }.frame(width: 600))
        XCTAssertEqual(inRow.height, 28, accuracy: 0.5)
    }

    func testLongBranchNamesAreCutRatherThanWidening() {
        let long = "feature/very-long-branch-name-that-keeps-going"
        let width = size(of: BranchBadge(branch: long)).width
        XCTAssertLessThan(width, 210, "a long branch is shortened, not shown in full")
        XCTAssertGreaterThan(width, size(of: BranchBadge(branch: "main")).width)
    }
}
