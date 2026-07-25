import XCTest
@testable import Uncoil

/// Sidebar order for projects: pinned first, then whatever the user dragged
/// into place.
@MainActor
final class ProjectOrderingTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilProjectOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(directory: root)
        for name in ["alpha", "beta", "gamma"] {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            store.addProject(at: path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var names: [String] { store.projects.map(\.name) }

    func testProjectsStartInTheOrderTheyWereAdded() {
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    func testDraggingOneProjectBeforeAnotherReordersTheSidebar() {
        let gamma = store.projects[2].id
        let alpha = store.projects[0].id
        store.moveProject(gamma, before: alpha)
        XCTAssertEqual(names, ["gamma", "alpha", "beta"])
    }

    func testPinningLiftsAProjectToTheTopAndUnpinningPutsItBack() {
        let gamma = store.projects[2].id
        store.toggleProjectPin(gamma)
        XCTAssertEqual(names.first, "gamma")
        store.toggleProjectPin(gamma)
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    /// Two pinned projects keep their own order relative to each other.
    func testPinnedProjectsKeepTheirRelativeOrder() {
        store.toggleProjectPin(store.projects[2].id)
        store.toggleProjectPin(store.projects.first(where: { $0.name == "beta" })!.id)
        XCTAssertEqual(Set(names.prefix(2)), ["gamma", "beta"])
        XCTAssertEqual(names.last, "alpha")
    }

    func testNudgingMovesOneStepAndStopsAtTheEnds() {
        let beta = store.projects[1].id
        store.nudgeProject(beta, by: -1)
        XCTAssertEqual(names, ["beta", "alpha", "gamma"])
        store.nudgeProject(beta, by: -1)
        XCTAssertEqual(names, ["beta", "alpha", "gamma"], "already first")
        store.nudgeProject(beta, by: 1)
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    /// Nudging into the pinned block pins the project, otherwise the sort would
    /// snap it straight back.
    func testNudgingIntoThePinnedBlockPins() {
        let alpha = store.projects[0].id
        store.toggleProjectPin(alpha)
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
        let beta = store.projects[1].id
        store.nudgeProject(beta, by: -1)
        XCTAssertEqual(names.first, "beta")
        XCTAssertTrue(store.projects.first { $0.id == beta }?.isPinned ?? false)
    }

    func testTheOrderSurvivesAReload() {
        let gamma = store.projects[2].id
        store.moveProject(gamma, before: store.projects[0].id)
        store.toggleProjectPin(store.projects.first(where: { $0.name == "beta" })!.id)
        let reloaded = ProjectStore(directory: root)
        XCTAssertEqual(reloaded.projects.map(\.name), ["beta", "gamma", "alpha"])
    }
}
