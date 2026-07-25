import XCTest
@testable import Uncoil

final class SidebarDragPayloadTests: XCTestCase {
    func testProjectPayloadRoundTrips() {
        let id = UUID()
        let string = SidebarDragPayload.project(id).pasteboardString
        XCTAssertEqual(SidebarDragPayload.parse(string), .project(id))
    }

    func testSessionPayloadKeepsTheSortedCommaFormatOtherScreensRead() {
        let ids = [UUID(), UUID(), UUID()]
        let string = SidebarDragPayload.sessions(ids).pasteboardString
        XCTAssertEqual(string, ids.map(\.uuidString).sorted().joined(separator: ","))
        XCTAssertEqual(
            SidebarDragPayload.parse(string),
            .sessions(ids.sorted { $0.uuidString < $1.uuidString })
        )
    }

    func testGarbageIsNotAPayload() {
        XCTAssertNil(SidebarDragPayload.parse(""))
        XCTAssertNil(SidebarDragPayload.parse("not-a-uuid"))
        XCTAssertNil(SidebarDragPayload.parse("project:nope"))
    }
}

final class SidebarDropResolverTests: XCTestCase {
    private let projectA = UUID()
    private let projectB = UUID()
    private let groupInA = UUID()
    private let groupInB = UUID()
    private let sessionA1 = UUID()
    private let sessionA2 = UUID()
    private let sessionB1 = UUID()

    private var context: SidebarDropContext {
        SidebarDropContext(
            projectIDs: [projectA, projectB],
            projectOfGroup: [groupInA: projectA, groupInB: projectB],
            projectOfSession: [sessionA1: projectA, sessionA2: projectA, sessionB1: projectB]
        )
    }

    func testProjectDroppedAtRootReorders() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .project(projectB), parent: .root, childIndex: 0, context: context
            ),
            .reorderProjects(dragged: projectB, toIndex: 0)
        )
    }

    func testProjectDroppedOnRootWithNoSlotAppends() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .project(projectA), parent: .root, childIndex: -1, context: context
            ),
            .reorderProjects(dragged: projectA, toIndex: 2)
        )
    }

    func testProjectDroppedInsideAnotherProjectIsRefused() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .project(projectB),
                parent: .project(projectA),
                childIndex: 0,
                context: context
            ),
            .refuse
        )
    }

    func testSessionsDroppedOnProjectLeaveTheirGroup() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1]),
                parent: .project(projectA),
                childIndex: 1,
                context: context
            ),
            .moveSessions(ids: [sessionA1], projectID: projectA, groupID: nil, toIndex: 1)
        )
    }

    func testSessionsDroppedOnGroupJoinIt() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1, sessionA2]),
                parent: .group(groupInA),
                childIndex: -1,
                context: context
            ),
            .moveSessions(
                ids: [sessionA1, sessionA2], projectID: projectA, groupID: groupInA, toIndex: -1
            )
        )
    }

    func testCrossProjectDropIsRefused() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1]),
                parent: .project(projectB),
                childIndex: 0,
                context: context
            ),
            .refuse
        )
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1]),
                parent: .group(groupInB),
                childIndex: 0,
                context: context
            ),
            .refuse
        )
    }

    func testMixedProjectSelectionIsRefusedRatherThanPartlyApplied() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1, sessionB1]),
                parent: .group(groupInA),
                childIndex: 0,
                context: context
            ),
            .refuse
        )
    }

    func testUnknownSessionsAreIgnoredAndAnEmptyDragRefused() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([UUID()]),
                parent: .project(projectA),
                childIndex: 0,
                context: context
            ),
            .refuse
        )
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1, UUID()]),
                parent: .project(projectA),
                childIndex: 0,
                context: context
            ),
            .moveSessions(ids: [sessionA1], projectID: projectA, groupID: nil, toIndex: 0)
        )
    }

    func testSessionsDroppedAtRootAreRefused() {
        XCTAssertEqual(
            SidebarDropResolver.plan(
                payload: .sessions([sessionA1]), parent: .root, childIndex: 0, context: context
            ),
            .refuse
        )
    }
}

final class SidebarReorderTests: XCTestCase {
    func testMovingUpLandsOnTheSlot() {
        XCTAssertEqual(
            SidebarReorder.moved(["a", "b", "c", "d"], dragged: "d", toIndex: 1),
            ["a", "d", "b", "c"]
        )
    }

    func testMovingDownAccountsForItsOwnRemoval() {
        XCTAssertEqual(
            SidebarReorder.moved(["a", "b", "c", "d"], dragged: "a", toIndex: 2),
            ["b", "a", "c", "d"]
        )
    }

    func testDroppingJustBelowItselfChangesNothing() {
        XCTAssertEqual(
            SidebarReorder.moved(["a", "b", "c"], dragged: "b", toIndex: 2),
            ["a", "b", "c"]
        )
    }

    func testIndexPastTheEndAppends() {
        XCTAssertEqual(
            SidebarReorder.moved(["a", "b", "c"], dragged: "a", toIndex: 99),
            ["b", "c", "a"]
        )
    }

    func testUnknownDraggedItemIsLeftAlone() {
        XCTAssertEqual(SidebarReorder.moved(["a", "b"], dragged: "z", toIndex: 0), ["a", "b"])
    }

    // MARK: - Sibling-relative moves

    /// The project holds five sessions; two of them are in a group. Dropping an
    /// ungrouped session at the group's second slot has to land between the two
    /// group rows in the project-wide order, not at project index 1.
    func testDropIntoASectionLandsBetweenThatSectionsRows() {
        let order = ["u1", "g1", "g2", "u2", "u3"]
        XCTAssertEqual(
            SidebarReorder.moved(order, siblings: ["g1", "g2"], dragged: ["u3"], toIndex: 1),
            ["u1", "g1", "u3", "g2", "u2"]
        )
    }

    func testAppendingToASectionLandsAfterItsLastRowNotAtTheEnd() {
        let order = ["g1", "g2", "u1", "u2"]
        XCTAssertEqual(
            SidebarReorder.moved(order, siblings: ["g1", "g2"], dragged: ["u1"], toIndex: -1),
            ["g1", "g2", "u1", "u2"]
        )
        XCTAssertEqual(
            SidebarReorder.moved(order, siblings: ["g1", "g2"], dragged: ["u2"], toIndex: -1),
            ["g1", "g2", "u2", "u1"]
        )
    }

    func testDropIntoAnEmptySectionGoesToTheEnd() {
        XCTAssertEqual(
            SidebarReorder.moved(["a", "b", "c"], siblings: [], dragged: ["a"], toIndex: -1),
            ["b", "c", "a"]
        )
    }

    func testMultipleDraggedRowsStayInOrderAndSkipThemselvesAsAnchor() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(
            SidebarReorder.moved(order, siblings: order, dragged: ["b", "d"], toIndex: 3),
            ["a", "c", "b", "d", "e"]
        )
    }

    func testReorderingWithinASectionUsesPreRemovalIndexes() {
        let order = ["s1", "s2", "s3"]
        XCTAssertEqual(
            SidebarReorder.moved(order, siblings: order, dragged: ["s1"], toIndex: 2),
            ["s2", "s1", "s3"]
        )
    }
}
