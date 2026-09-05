import XCTest
@testable import Uncoil

/// "Look for this project's setup" was written three times — the General page's
/// offer, the Run tab's Detect button, the Tests tab's empty state — and the
/// copies had drifted: one reported what it found and one silently did nothing,
/// one surfaced a write failure and one swallowed it.
@MainActor
final class ProjectSetupTests: XCTestCase {
    private var root: URL!
    private var project: Project!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = Project(name: "demo", rootPath: root.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Nothing is invented: a folder with no dev server and no test setup gets
    /// no configuration, and the tab stays away.
    func testAnEmptyFolderYieldsNothing() async {
        let run = await ProjectSetup.look(for: .run, in: project)
        XCTAssertEqual(run.added, 0)
        XCTAssertNil(run.error)
        XCTAssertFalse(ProjectDetector.detect(projectRoot: root.path).has(.run))
    }

    func testWhatIsFoundIsWrittenDownAndBecomesACapability() async throws {
        try #"{"scripts":{"dev":"node server.js"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let outcome = await ProjectSetup.look(for: .run, in: project)
        XCTAssertGreaterThan(outcome.added, 0)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(
            ProjectDetector.detect(projectRoot: root.path).has(.run),
            "the Run tab exists because the setup wrote something, not because it was asked to"
        )
    }

    /// Merging rather than replacing: looking twice must not double what is
    /// there, and must not overwrite what the user wrote by hand.
    func testLookingTwiceAddsNothingTheSecondTime() async throws {
        try #"{"scripts":{"dev":"node server.js"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let first = await ProjectSetup.look(for: .run, in: project)
        let second = await ProjectSetup.look(for: .run, in: project)
        XCTAssertGreaterThan(first.added, 0)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(
            RunConfigFile.load(projectRoot: root).configurations.count, first.added
        )
    }

    /// A task list is written rather than found, and a file that is already
    /// there is not a failure — the point was to have one.
    func testATaskListIsCreatedAndAnExistingOneIsLeftAlone() async throws {
        let first = await ProjectSetup.look(for: .tasks, in: project)
        XCTAssertNil(first.error)
        XCTAssertTrue(ProjectDetector.detect(projectRoot: root.path).has(.tasks))

        let before = try String(contentsOf: root.appendingPathComponent("TODO.md"), encoding: .utf8)
        let second = await ProjectSetup.look(for: .tasks, in: project)
        XCTAssertNil(second.error)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("TODO.md"), encoding: .utf8),
            before,
            "a second look must not rewrite the file the user has been editing"
        )
    }

    /// Nothing in the app can give a folder a GitHub remote, so that offer
    /// explains rather than promising a button that cannot work.
    func testOnlyWhatUncoilCanActOnIsActionable() {
        XCTAssertTrue(ProjectSetup.isActionable(.run))
        XCTAssertTrue(ProjectSetup.isActionable(.tests))
        XCTAssertTrue(ProjectSetup.isActionable(.tasks))
        XCTAssertFalse(ProjectSetup.isActionable(.gitHubRepository))
        XCTAssertFalse(ProjectArea.issues.offerIsActionable)
        XCTAssertTrue(ProjectArea.run.offerIsActionable)
    }
}
