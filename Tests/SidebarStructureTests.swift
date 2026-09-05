import XCTest
@testable import Uncoil

/// Folding a project used to hide everything under it, including the session
/// open on the right — so the sidebar could show no trace of the agent filling
/// the rest of the window, and there was no row to click back to.
final class SidebarRevealTests: XCTestCase {
    private let project = UUID()
    private let other = UUID()
    private let session = UUID()
    private let sibling = UUID()

    private var structure: SidebarStructure {
        SidebarStructure.build(
            projectIDs: [project, other],
            groups: { _ in [] },
            sessions: { id in
                id == self.project
                    ? [(self.session, nil, nil), (self.sibling, nil, nil)]
                    : []
            }
        )
    }

    func testAnOpenProjectIsLeftExactlyAsItIs() {
        let revealed = structure.revealing(sessionID: session, inCollapsed: [])
        XCTAssertEqual(revealed, structure)
    }

    func testAFoldedProjectKeepsOnlyTheSessionYouAreLookingAt() {
        let revealed = structure.revealing(sessionID: session, inCollapsed: [project])
        XCTAssertEqual(revealed.projects[0].ungrouped.map(\.id), [session])
        XCTAssertTrue(revealed.projects[0].groups.isEmpty)
    }

    func testAFoldedProjectWithNothingOpenInItShowsNothing() {
        let revealed = structure.revealing(sessionID: session, inCollapsed: [project, other])
        XCTAssertTrue(revealed.projects[1].ungrouped.isEmpty, "the session is not in that project")
    }

    func testFoldingWithNoSessionOpenAtAllHidesEverything() {
        let revealed = structure.revealing(sessionID: nil, inCollapsed: [project])
        XCTAssertTrue(revealed.projects[0].ungrouped.isEmpty)
    }

    /// A sub-agent is shown at the project's top level rather than with the
    /// branch it came from rebuilt around it: the point is a row that says
    /// "this is where you are".
    func testASubAgentIsRevealedWithoutItsBranch() {
        let parent = UUID()
        let child = UUID()
        let nested = SidebarStructure.build(
            projectIDs: [project],
            groups: { _ in [] },
            sessions: { _ in [(parent, nil, nil), (child, nil, parent)] }
        )
        let revealed = nested.revealing(sessionID: child, inCollapsed: [project])
        XCTAssertEqual(revealed.projects[0].ungrouped.map(\.id), [child])
        XCTAssertTrue(revealed.projects[0].ungrouped[0].children.isEmpty)
    }
}

/// The rule was first written against the selection changing, and the case that
/// matters most — folding the project you are already on — changes no selection
/// at all. So it never ran, and with the disclosure chevron gone a folded
/// project had no way back open.
final class ProjectRowClickTests: XCTestCase {
    func testAFoldedProjectOpens() {
        XCTAssertEqual(
            ProjectRowClick.outcome(isFolded: true, wasAlreadySelected: false), .open
        )
        XCTAssertEqual(
            ProjectRowClick.outcome(isFolded: true, wasAlreadySelected: true), .open
        )
    }

    func testTheProjectYouAreOnFoldsAway() {
        XCTAssertEqual(
            ProjectRowClick.outcome(isFolded: false, wasAlreadySelected: true), .fold
        )
    }

    /// Arriving at a project must never hide what it is holding — that is what
    /// you came to look at.
    func testArrivingFromElsewhereOnlySelects() {
        XCTAssertEqual(
            ProjectRowClick.outcome(isFolded: false, wasAlreadySelected: false), .leaveAlone
        )
    }
}
