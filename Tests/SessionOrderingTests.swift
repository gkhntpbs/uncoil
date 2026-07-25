import XCTest
@testable import Uncoil

/// Sidebar order for sessions: pinned first, then whatever the user dragged or
/// nudged into place — kept per group, because the sidebar shows a project's
/// sessions split into sections while the order itself is stored project-wide.
@MainActor
final class SessionOrderingTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private var projectID: UUID!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSessionOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(directory: root)
        let path = root.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        store.addProject(at: path)
        projectID = store.projects[0].id
        for title in ["one", "two", "three"] {
            store.createSession(
                projectID: projectID, provider: .terminal, accountID: nil, title: title
            )
        }
        // Without a sort index sessions fall back to newest-activity-first, so
        // they start as three, two, one. Freeze a known order into indexes first
        // and the assertions are then about moves rather than timestamps.
        store.moveSessions(titles(["one"]), toGroup: nil, inProject: projectID, at: 0)
        store.moveSessions(titles(["two"]), toGroup: nil, inProject: projectID, at: 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var titles: [String] { store.sessions(for: projectID).map(\.title) }

    private func titles(_ wanted: [String]) -> [UUID] {
        wanted.compactMap { title in store.sessions.first { $0.title == title }?.id }
    }

    private func id(_ title: String) -> UUID {
        store.sessions.first { $0.title == title }!.id
    }

    func testSessionsStartInTheOrderTheyWerePutIn() {
        XCTAssertEqual(titles, ["one", "two", "three"])
    }

    /// The fallback before anyone reorders anything: the most recently active
    /// session sits at the top.
    func testWithoutAManualOrderTheNewestSessionComesFirst() throws {
        let path = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        store.addProject(at: path)
        let fresh = try XCTUnwrap(store.projects.first { $0.name == "fresh" }).id
        for title in ["older", "newer"] {
            store.createSession(
                projectID: fresh, provider: .terminal, accountID: nil, title: title
            )
        }
        XCTAssertEqual(store.sessions(for: fresh).map(\.title), ["newer", "older"])
    }

    func testNudgingASessionMovesItOneStepAmongItsSiblings() {
        store.nudgeSession(id("three"), by: -1)
        XCTAssertEqual(titles, ["one", "three", "two"])
        store.nudgeSession(id("three"), by: 1)
        XCTAssertEqual(titles, ["one", "two", "three"])
    }

    func testNudgingPastTheEndsDoesNothing() {
        store.nudgeSession(id("one"), by: -1)
        XCTAssertEqual(titles, ["one", "two", "three"])
        store.nudgeSession(id("three"), by: 1)
        XCTAssertEqual(titles, ["one", "two", "three"])
    }

    func testPinningLiftsASessionAndNudgingCarriesThePinAcrossTheBoundary() {
        store.togglePin(id("three"))
        XCTAssertEqual(titles, ["three", "one", "two"])
        // Stepping down out of the pinned block gives up the pin, or the sort
        // would put the session straight back on top.
        store.nudgeSession(id("three"), by: 1)
        XCTAssertEqual(titles.first, "one")
        XCTAssertNotEqual(store.sessions.first { $0.title == "three" }?.isPinned, true)
    }

    // MARK: - Groups

    func testDroppingSessionsIntoAGroupMovesThemAndKeepsTheirOrder() throws {
        let group = try XCTUnwrap(store.createGroup(projectID: projectID, name: "grup"))
        store.moveSessions(
            titles(["one", "three"]), toGroup: group.id, inProject: projectID, at: -1
        )
        XCTAssertEqual(store.sessions(in: group.id).map(\.title), ["one", "three"])
        XCTAssertEqual(
            store.sessions(for: projectID).filter { $0.groupID == nil }.map(\.title), ["two"]
        )
    }

    func testReorderingInsideAGroupLeavesTheLooseSessionsAlone() throws {
        let group = try XCTUnwrap(store.createGroup(projectID: projectID, name: "grup"))
        store.moveSessions(
            titles(["one", "two"]), toGroup: group.id, inProject: projectID, at: -1
        )
        store.nudgeSession(id("two"), by: -1)
        XCTAssertEqual(store.sessions(in: group.id).map(\.title), ["two", "one"])
        XCTAssertEqual(
            store.sessions(for: projectID).filter { $0.groupID == nil }.map(\.title), ["three"]
        )
    }

    func testTakingASessionOutOfAGroupPutsItBackWithTheLooseOnes() throws {
        let group = try XCTUnwrap(store.createGroup(projectID: projectID, name: "grup"))
        store.moveSessions(titles(["one"]), toGroup: group.id, inProject: projectID, at: -1)
        store.moveSessions(titles(["one"]), toGroup: nil, inProject: projectID, at: -1)
        XCTAssertTrue(store.sessions(in: group.id).isEmpty)
        XCTAssertEqual(store.sessions.first { $0.title == "one" }?.groupID, nil)
    }

    func testAGroupFromAnotherProjectIsRefusedRatherThanStealingTheSession() throws {
        let otherPath = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: otherPath, withIntermediateDirectories: true)
        store.addProject(at: otherPath)
        let other = try XCTUnwrap(store.projects.first { $0.name == "beta" })
        let foreign = try XCTUnwrap(store.createGroup(projectID: other.id, name: "yabancı"))

        store.moveSessions(titles(["one"]), toGroup: foreign.id, inProject: projectID, at: -1)
        XCTAssertEqual(store.sessions.first { $0.title == "one" }?.groupID, nil)
    }

    /// An empty group is a valid drop target, which is the point of being able
    /// to create one from the project's context menu.
    func testAGroupCanBeCreatedEmptyAndFilledAfterwards() throws {
        let group = try XCTUnwrap(store.createGroup(projectID: projectID, name: "boş"))
        XCTAssertTrue(store.sessions(in: group.id).isEmpty)
        store.moveSessions(titles(["two"]), toGroup: group.id, inProject: projectID, at: 0)
        XCTAssertEqual(store.sessions(in: group.id).map(\.title), ["two"])
    }
}

/// The sidebar's nesting: a project's rows have to know how deep they sit, or
/// sessions draw at the same inset as the project above them and the whole tree
/// reads as one flat list.
final class SidebarStructureDepthTests: XCTestCase {
    private let project = UUID()
    private let group = UUID()
    private let grouped = UUID()
    private let loose = UUID()

    private var structure: SidebarStructure {
        SidebarStructure.build(
            projectIDs: [project],
            groups: { _ in [self.group] },
            sessions: { _ in [(self.grouped, self.group), (self.loose, nil)] }
        )
    }

    func testDepthPlacesProjectsGroupsAndSessions() {
        XCTAssertEqual(structure.depth(of: .project(project)), 0)
        XCTAssertEqual(structure.depth(of: .group(group)), 1)
        XCTAssertEqual(structure.depth(of: .session(loose)), 1)
        XCTAssertEqual(structure.depth(of: .session(grouped)), 2)
    }

    func testASessionWhoseGroupDisappearedIsShownAsALooseChild() {
        let orphaned = SidebarStructure.build(
            projectIDs: [project],
            groups: { _ in [] },
            sessions: { _ in [(self.grouped, self.group)] }
        )
        XCTAssertEqual(orphaned.projects.first?.ungrouped, [grouped])
        XCTAssertEqual(orphaned.depth(of: .session(grouped)), 1)
    }

    func testIndentAndRailsGrowWithDepth() {
        XCTAssertLessThan(SidebarIndent.leading(depth: 0), SidebarIndent.leading(depth: 1))
        XCTAssertLessThan(SidebarIndent.leading(depth: 1), SidebarIndent.leading(depth: 2))
        XCTAssertTrue(SidebarIndent.rails(depth: 0).isEmpty)
        XCTAssertEqual(SidebarIndent.rails(depth: 1).count, 1)
        XCTAssertEqual(SidebarIndent.rails(depth: 2).count, 2)
    }
}

/// The pinned marker is the same pin as the button, filled.
///
/// It used to be drawn as `TablerIcon(name: "pinned-filled")`, which showed up as
/// a coloured dot: `TablerIcon` falls back to a dot for a name it does not know,
/// and the bundled font is the outline set with no filled variants at all. So the
/// pair comes from SF Symbols instead — asserted here, because a missing symbol
/// name fails the same silent way.
final class SidebarIconNameTests: XCTestCase {
    func testBothHalvesOfThePinPairExist() {
        for name in ["pin", "pin.fill"] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "The \(name) symbol is gone; the pin would render as nothing"
            )
        }
    }

    func testTheBundledFontStillHasNoFilledVariantToReachFor() {
        XCTAssertTrue(
            TablerIcons.map.keys.allSatisfy { !$0.hasSuffix("-filled") },
            "A filled icon set is bundled now; the pin could come from it instead"
        )
    }
}
