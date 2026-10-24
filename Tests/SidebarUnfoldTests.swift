import XCTest
@testable import Uncoil

final class SidebarUnfoldTests: XCTestCase {
    private let folded = UUID()
    private let open = UUID()

    func testANewSessionOpensItsFoldedProject() {
        let old = UUID(), new = UUID()
        let result = SidebarUnfold.projects(
            known: [old],
            current: [(old, folded), (new, folded)],
            collapsed: [folded]
        )
        XCTAssertEqual(result, [folded])
    }

    func testTheFirstPassUnfoldsNothing() {
        XCTAssertEqual(SidebarUnfold.projects(
            known: nil, current: [(UUID(), folded)], collapsed: [folded]
        ), [])
    }

    func testAnOpenProjectAndKnownSessionsAreLeftAlone() {
        let old = UUID()
        XCTAssertEqual(SidebarUnfold.projects(
            known: [old], current: [(old, folded), (UUID(), open)], collapsed: [folded]
        ), [])
    }
}
