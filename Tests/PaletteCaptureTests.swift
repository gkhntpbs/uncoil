import XCTest
@testable import Uncoil

/// Capturing a task from the palette: one keystroke more than the thought.
final class PaletteCaptureTests: XCTestCase {
    private let project = UUID()

    private func context(
        query: String, targets: [PaletteCaptureTarget], currentProject: UUID? = nil
    ) -> PaletteContext {
        PaletteContext(
            query: query,
            projects: [],
            sessions: [],
            statuses: [:],
            currentProjectID: currentProject ?? project,
            currentSessionID: nil,
            files: [],
            artifacts: [],
            projectRoot: "/p",
            settingsPanes: [],
            captureTargets: targets
        )
    }

    private var targets: [PaletteCaptureTarget] {
        [
            PaletteCaptureTarget(
                sourcePath: "/p/TODO.md", displayPath: "TODO.md",
                heading: ["TODO", "Next"], rank: 100
            ),
            PaletteCaptureTarget(
                sourcePath: "/p/TODO.md", displayPath: "TODO.md",
                heading: ["TODO", "Later"], rank: 99
            ),
            PaletteCaptureTarget(
                sourcePath: "/p/docs/TODO.md", displayPath: "docs/TODO.md",
                heading: ["TODO", "Ideas"], rank: 0
            ),
        ]
    }

    // MARK: - The prefix

    func testAPlusStartsACapture() {
        XCTAssertEqual(PaletteEngine.capturePrompt(in: "+ fix the parser"), "fix the parser")
        XCTAssertEqual(PaletteEngine.capturePrompt(in: "todo: fix it"), "fix it")
        XCTAssertEqual(PaletteEngine.capturePrompt(in: "task: fix it"), "fix it")
    }

    func testAnOrdinarySearchIsNotACapture() {
        XCTAssertNil(PaletteEngine.capturePrompt(in: "settings"))
        XCTAssertNil(PaletteEngine.capturePrompt(in: "a + b"))
    }

    /// `>` is the commands-only prefix and has to keep meaning that.
    func testTheCommandPrefixIsNotHijacked() {
        XCTAssertNil(PaletteEngine.capturePrompt(in: "> + something"))
    }

    /// A question is not a task. The two prefixes must not both fire, or Enter
    /// would mean two things at once.
    func testAskingAndCapturingDoNotOverlap() {
        XCTAssertNil(PaletteEngine.capturePrompt(in: "? what does this do"))
        XCTAssertNil(PaletteEngine.askPrompt(in: "+ fix the parser"))
    }

    // MARK: - Destinations

    func testEveryHeadingIsOfferedAsADestination() {
        let items = PaletteEngine.captureItems(raw: "+ fix it", ctx: context(
            query: "+ fix it", targets: targets
        ))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.title, "TODO › Next")
    }

    /// The capture takes the palette over, the way asking does: with files and
    /// projects mixed in, Enter would be ambiguous.
    func testCapturingTakesThePaletteOver() {
        let groups = PaletteEngine.compute(context(query: "+ fix it", targets: targets))
        XCTAssertEqual(groups.map(\.kind), [.capture])
    }

    /// A project with no task file has nowhere to put it. Offering to file it
    /// anyway would promise a write that cannot happen.
    func testWithNoTaskFileThereIsNothingToCaptureInto() {
        let groups = PaletteEngine.compute(context(query: "+ fix it", targets: []))
        XCTAssertFalse(groups.contains { $0.kind == .capture })
    }

    func testAnEmptyTaskIsNotOffered() {
        XCTAssertTrue(
            PaletteEngine.captureItems(raw: "+", ctx: context(query: "+", targets: targets))
                .isEmpty
        )
        XCTAssertTrue(
            PaletteEngine.captureItems(raw: "+   ", ctx: context(query: "+   ", targets: targets))
                .isEmpty
        )
    }

    /// Nothing to capture into without a project in view.
    func testNoCaptureWithoutACurrentProject() {
        let ctx = PaletteContext(
            query: "+ fix it", projects: [], sessions: [], statuses: [:],
            currentProjectID: nil, currentSessionID: nil, files: [], artifacts: [],
            projectRoot: nil, settingsPanes: [], captureTargets: targets
        )
        XCTAssertTrue(PaletteEngine.captureItems(raw: "+ fix it", ctx: ctx).isEmpty)
    }

    /// The action carries everything the write needs, so performing it never
    /// has to re-derive which file or heading was chosen.
    func testTheActionNamesItsFileAndHeading() throws {
        let items = PaletteEngine.captureItems(raw: "+ fix it", ctx: context(
            query: "+ fix it", targets: targets
        ))
        let action = try XCTUnwrap(items.first?.action)
        guard case .captureTask(let text, let projectID, let path, let heading) = action else {
            return XCTFail("expected a capture action, got \(action)")
        }
        XCTAssertEqual(text, "fix it")
        XCTAssertEqual(projectID, project)
        XCTAssertEqual(path, "/p/TODO.md")
        XCTAssertEqual(heading, ["TODO", "Next"])
    }

    /// Two files both called TODO.md would give identical rows without it.
    func testASecondFilesHeadingSaysWhichFileItIs() throws {
        let items = PaletteEngine.captureItems(raw: "+ fix it", ctx: context(
            query: "+ fix it", targets: targets
        ))
        let nested = try XCTUnwrap(items.first { $0.title == "TODO › Ideas" })
        XCTAssertEqual(nested.subtitle, "docs/TODO.md")
    }
}
