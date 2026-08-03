import XCTest
@testable import Uncoil

/// A project with more than one task file has more than one file called
/// `TODO.md`. Naming a task by its last path component makes every one of them
/// read the same, which is the bug these tests exist to keep fixed.
final class TaskSourceLabelTests: XCTestCase {
    private func source(path: String, displayPath: String) -> ProjectTaskSource {
        ProjectTaskSource(
            path: path,
            projectID: UUID(),
            displayPath: displayPath,
            contentHash: "hash",
            lastReadAt: .now,
            taskCount: 1,
            openTaskCount: 1
        )
    }

    func testTheRecordedDisplayPathIsPreferred() {
        let known = [source(path: "/p/docs/TODO.md", displayPath: "docs/TODO.md")]
        XCTAssertEqual(
            TaskSourceLabel.displayPath(
                forSourcePath: "/p/docs/TODO.md", knownSources: known, projectRoot: "/p"
            ),
            "docs/TODO.md"
        )
    }

    /// The scan carries the relative path through the walk because a root that
    /// normalises to `/var` never prefixes a child enumerated under
    /// `/private/var`. Trusting the record is what keeps that working.
    func testTheRecordWinsOverRecomputingFromAMismatchedRoot() {
        let known = [source(path: "/private/var/p/docs/TODO.md", displayPath: "docs/TODO.md")]
        XCTAssertEqual(
            TaskSourceLabel.displayPath(
                forSourcePath: "/private/var/p/docs/TODO.md",
                knownSources: known,
                projectRoot: "/var/p"
            ),
            "docs/TODO.md"
        )
    }

    func testAnUnknownPathFallsBackToTheRelativePath() {
        XCTAssertEqual(
            TaskSourceLabel.displayPath(
                forSourcePath: "/p/App/TODO.md", knownSources: [], projectRoot: "/p"
            ),
            "App/TODO.md"
        )
    }

    func testTwoSourcesNamedTheSameGetDifferentLabels() {
        let known = [
            source(path: "/p/TODO.md", displayPath: "TODO.md"),
            source(path: "/p/docs/TODO.md", displayPath: "docs/TODO.md"),
        ]
        let root = TaskSourceLabel.displayPath(
            forSourcePath: "/p/TODO.md", knownSources: known, projectRoot: "/p"
        )
        let nested = TaskSourceLabel.displayPath(
            forSourcePath: "/p/docs/TODO.md", knownSources: known, projectRoot: "/p"
        )
        XCTAssertNotEqual(TaskSourceLabel.short(displayPath: root),
                          TaskSourceLabel.short(displayPath: nested))
    }

    func testAShortPathIsShownWhole() {
        XCTAssertEqual(TaskSourceLabel.short(displayPath: "TODO.md"), "TODO.md")
        XCTAssertEqual(TaskSourceLabel.short(displayPath: "docs/TODO.md"), "docs/TODO.md")
    }

    /// The folder immediately above the file is what distinguishes it, so that
    /// is the part kept when the path is too long for a row.
    func testADeepPathKeepsTheFolderThatDistinguishesIt() {
        XCTAssertEqual(
            TaskSourceLabel.short(displayPath: "packages/core/docs/TODO.md"),
            "…/docs/TODO.md"
        )
    }

    /// An agent has to be able to open the file from the project root, so the
    /// prompt never gets the shortened form.
    func testThePromptLocationCarriesTheWholePath() {
        let location = TaskSourceLabel.location(
            displayPath: "packages/core/docs/TODO.md", headingPath: ["Next"]
        )
        XCTAssertEqual(location, "packages/core/docs/TODO.md › Next")
        XCTAssertFalse(location.contains("…"))
    }

    func testAHeadinglessTaskIsNamedByItsFileAlone() {
        XCTAssertEqual(
            TaskSourceLabel.location(displayPath: "docs/TODO.md", headingPath: []),
            "docs/TODO.md"
        )
    }
}
