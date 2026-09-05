import XCTest
@testable import Uncoil

/// The project's stack used to be detected once per feature — a TODO scan for
/// the Tasks tab, a config read for Run, a remote walk for Issues — each in its
/// own place and on its own schedule. These tests pin the replacement: one set
/// of capabilities, and areas that are a consequence of it.
final class ProjectCapabilityTests: XCTestCase {
    func testACapabilityIsPresentOnlyWhenItWasSet() {
        var capabilities = ProjectCapabilities.none
        XCTAssertFalse(capabilities.has(.tasks))
        capabilities.set(.tasks, true)
        XCTAssertTrue(capabilities.has(.tasks))
        capabilities.set(.tasks, false)
        XCTAssertEqual(capabilities, .none)
    }

    /// Being a repository is worth knowing and is not a tab: the check exists
    /// so that nothing gates a tab on it by accident.
    func testBeingARepositoryOpensNoArea() {
        XCTAssertNil(ProjectAreaAvailability.capability(for: .overview))
        XCTAssertEqual(ProjectAreaAvailability.areas(ProjectCapabilities([.git])), [.overview])
    }

    /// A new area without a capability would be shown on every project, which
    /// is the failure this whole registry replaced.
    func testEveryAreaBesidesGeneralIsGatedOnACapability() {
        for area in ProjectArea.allCases where area != .overview {
            XCTAssertNotNil(
                ProjectAreaAvailability.capability(for: area),
                "\(area) would be shown on every project, including the folders that have nothing"
            )
        }
    }

    /// Detection has to answer for a folder that is not a project at all —
    /// it is what a freshly added empty directory looks like.
    func testAnEmptyFolderHasNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-capabilities-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capabilities = ProjectDetector.detect(projectRoot: root.path)
        XCTAssertFalse(capabilities.has(.tasks))
        XCTAssertFalse(capabilities.has(.run))
        XCTAssertFalse(capabilities.has(.tests))
        XCTAssertEqual(ProjectAreaAvailability.areas(capabilities), [.overview])
    }

    func testATodoFileIsWhatMakesTheTasksTabExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-capabilities-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "- [ ] something\n".write(
            to: root.appendingPathComponent("TODO.md"), atomically: true, encoding: .utf8
        )

        let capabilities = ProjectDetector.detect(projectRoot: root.path)
        XCTAssertTrue(capabilities.has(.tasks))
        XCTAssertEqual(ProjectAreaAvailability.areas(capabilities), [.overview, .tasks])
    }
}
