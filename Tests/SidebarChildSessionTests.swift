import XCTest
@testable import Uncoil

/// An agent can spawn child sessions through the control plane, and a child is a
/// real session with its own terminal. `parentSessionID` has been on the record
/// and used by the control plane all along, but the sidebar ignored it — so a
/// sub-agent sat beside the agent that created it, and nothing said which one
/// was doing the work and which one was waiting.
final class SidebarChildSessionTests: XCTestCase {
    private let project = UUID()
    private let group = UUID()
    private let parent = UUID()
    private let child = UUID()
    private let grandchild = UUID()

    private func build(
        groups: [UUID] = [],
        _ sessions: [(id: UUID, groupID: UUID?, parentID: UUID?)]
    ) -> SidebarStructure {
        SidebarStructure.build(
            projectIDs: [project],
            groups: { _ in groups },
            sessions: { _ in sessions }
        )
    }

    func testAChildIsNestedUnderTheSessionThatSpawnedIt() {
        let structure = build([(parent, nil, nil), (child, nil, parent)])
        let roots = structure.projects.first?.ungrouped ?? []
        XCTAssertEqual(roots.map(\.id), [parent])
        XCTAssertEqual(roots.first?.children.map(\.id), [child])
    }

    /// A child drawn inside its parent must not also be drawn at the top level.
    func testAChildIsNotAlsoListedBesideItsParent() {
        let structure = build([(parent, nil, nil), (child, nil, parent)])
        let top = structure.projects.first?.ungrouped.map(\.id) ?? []
        XCTAssertFalse(top.contains(child))
    }

    func testNestingGoesDeeperThanOneLevel() {
        let structure = build([
            (parent, nil, nil), (child, nil, parent), (grandchild, nil, child),
        ])
        XCTAssertEqual(structure.depth(of: .session(parent)), 1)
        XCTAssertEqual(structure.depth(of: .session(child)), 2)
        XCTAssertEqual(structure.depth(of: .session(grandchild)), 3)
    }

    /// A child is placed by its parent, never by its own group — it is drawn
    /// inside the parent's row, and honouring the group too would draw it twice.
    func testAChildFollowsItsParentIntoAGroup() {
        let structure = build(
            groups: [group],
            [(parent, group, nil), (child, nil, parent)]
        )
        let grouped = structure.projects.first?.groups.first?.sessions ?? []
        XCTAssertEqual(grouped.map(\.id), [parent])
        XCTAssertEqual(grouped.first?.children.map(\.id), [child])
        XCTAssertTrue(structure.projects.first?.ungrouped.isEmpty ?? false)
        XCTAssertEqual(structure.depth(of: .session(child)), 3)
    }

    /// A parent that is gone — moved to another project, or ended and swept —
    /// must not take its child down with it.
    func testAnOrphanIsShownAtTheTopLevelRatherThanLost() {
        let structure = build([(child, nil, UUID())])
        XCTAssertEqual(structure.projects.first?.ungrouped.map(\.id), [child])
        XCTAssertFalse(structure.isChild(sessionID: child))
    }

    /// A cycle in the links would make a branch nothing ever reaches. Both
    /// sessions stay visible instead.
    func testACycleLosesNoSession() {
        let structure = build([(parent, nil, child), (child, nil, parent)])
        let shown = Set(SidebarStructure.flatten(structure.projects.first?.ungrouped ?? []))
        XCTAssertEqual(shown, [parent, child])
    }

    func testTheRowKnowsWhetherItIsAChild() {
        let structure = build([(parent, nil, nil), (child, nil, parent)])
        XCTAssertFalse(structure.isChild(sessionID: parent))
        XCTAssertTrue(structure.isChild(sessionID: child))
        XCTAssertEqual(structure.parent(ofSession: child), parent)
        XCTAssertNil(structure.parent(ofSession: parent))
    }

    /// A nested session missing from the drop context reads as belonging to no
    /// project at all.
    func testANestedSessionStillBelongsToItsProject() {
        let structure = build([(parent, nil, nil), (child, nil, parent)])
        XCTAssertEqual(structure.dropContext.projectOfSession[child], project)
    }

    func testAProjectWithOnlyAParentStillReportsChildren() {
        let structure = build([(parent, nil, nil), (child, nil, parent)])
        XCTAssertTrue(structure.hasChildren(projectID: project))
    }
}
