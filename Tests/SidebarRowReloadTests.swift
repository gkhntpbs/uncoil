import XCTest
@testable import Uncoil

/// A hosted row is built once and keeps what it was given, so anything a row
/// draws from outside its own record has to invalidate it explicitly. Two bugs
/// came from getting this wrong: switching multi-select on left the rows without
/// their checkboxes, and changing selection left the highlight on the old row.
@MainActor
final class SidebarRowReloadTests: XCTestCase {
    private let projectID = UUID()
    private let sessionA = UUID()
    private let sessionB = UUID()

    private func inputs(
        multi: Bool = false,
        selection: MainSelection? = nil,
        selected: Set<UUID> = []
    ) -> SidebarRowInputs {
        SidebarRowInputs(isMultiSelecting: multi, selection: selection, selected: selected)
    }

    func testTheFirstPassBuildsEverything() {
        XCTAssertEqual(SidebarRowReload.plan(from: nil, to: inputs()), .all)
    }

    func testNothingChangedReloadsNothing() {
        let same = inputs(selection: .session(sessionA))
        XCTAssertEqual(SidebarRowReload.plan(from: same, to: same), .items([]))
    }

    /// The checkbox column appears on every session row at once.
    func testTurningMultiSelectOnRebuildsEveryRow() {
        XCTAssertEqual(
            SidebarRowReload.plan(from: inputs(), to: inputs(multi: true)),
            .all
        )
        XCTAssertEqual(
            SidebarRowReload.plan(from: inputs(multi: true), to: inputs()),
            .all
        )
    }

    /// Only two rows change when selection moves: the one losing the highlight
    /// and the one gaining it.
    func testMovingTheSelectionRebuildsBothRows() {
        XCTAssertEqual(
            SidebarRowReload.plan(
                from: inputs(selection: .session(sessionA)),
                to: inputs(selection: .session(sessionB))
            ),
            .items([
                SidebarItem.session(sessionA).nodeID,
                SidebarItem.session(sessionB).nodeID,
            ])
        )
    }

    func testSelectingAProjectRebuildsTheRowThatLostItToo() {
        XCTAssertEqual(
            SidebarRowReload.plan(
                from: inputs(selection: .session(sessionA)),
                to: inputs(selection: .project(projectID))
            ),
            .items([
                SidebarItem.session(sessionA).nodeID,
                SidebarItem.project(projectID).nodeID,
            ])
        )
    }

    func testOnlyTheRowsJoiningOrLeavingABatchAreRebuilt() {
        XCTAssertEqual(
            SidebarRowReload.plan(
                from: inputs(multi: true, selected: [sessionA]),
                to: inputs(multi: true, selected: [sessionA, sessionB])
            ),
            .items([SidebarItem.session(sessionB).nodeID])
        )
    }

    func testClearingABatchRebuildsWhatWasInIt() {
        XCTAssertEqual(
            SidebarRowReload.plan(
                from: inputs(multi: true, selected: [sessionA, sessionB]),
                to: inputs(multi: true)
            ),
            .items([
                SidebarItem.session(sessionA).nodeID,
                SidebarItem.session(sessionB).nodeID,
            ])
        )
    }
}
