import XCTest
@testable import Uncoil

@MainActor
final class BlueprintStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: BlueprintStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-blueprints-\(UUID().uuidString)", isDirectory: true)
        store = BlueprintStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func project(name: String = "x-workspace", path: String = "/tmp/x") -> Project {
        var project = Project(name: name, rootPath: path)
        project.iconName = nil
        return project
    }

    // MARK: - File format

    func testABlueprintSurvivesTheRoundTripThroughItsFile() throws {
        let original = Blueprint(
            id: "full-stack",
            name: "Full-stack workspace",
            iconName: "layout-grid",
            colorHex: 0x4C8DFF,
            prompt: "Create api/, web/ and docs/.\n\nThen write CLAUDE.md.",
            startsImmediately: true
        )
        let parsed = try XCTUnwrap(
            Blueprint.parse(original.markdown(), id: "full-stack")
        )
        XCTAssertEqual(parsed, original)
    }

    /// The body is markdown and people will put `---` in it. Only the first one
    /// closes the front matter.
    func testAHorizontalRuleInThePromptIsNotAFrontMatterFence() throws {
        let text = """
        ---
        name: Rules
        startsImmediately: false
        ---

        First section

        ---

        Second section
        """
        let parsed = try XCTUnwrap(Blueprint.parse(text, id: "rules"))
        XCTAssertTrue(parsed.prompt.contains("Second section"))
        XCTAssertTrue(parsed.prompt.contains("---"))
    }

    func testSomethingThatIsNotABlueprintIsRefusedRatherThanGuessed() {
        XCTAssertNil(Blueprint.parse("just a note", id: "x"))
        XCTAssertNil(Blueprint.parse("---\nicon: x\n---\nbody", id: "x"), "no name")
        XCTAssertNil(Blueprint.parse("", id: "x"))
    }

    /// One unreadable file must not empty the list — the folder is meant to be
    /// somewhere people drop things.
    func testAStrayFileDoesNotTakeTheListDown() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not a blueprint".utf8)
            .write(to: tempDir.appendingPathComponent("notes.md"))
        try store.save(Blueprint(id: "real", name: "Real", prompt: "do the thing"))

        XCTAssertEqual(store.blueprints.map(\.id), ["real"])
    }

    // MARK: - Placeholders

    func testThePlaceholdersAreFilledFromTheProject() {
        let blueprint = Blueprint(
            id: "b", name: "B",
            prompt: "Set up {{project_name}} at {{project_path}}, then open {{project_name}}/api."
        )
        XCTAssertEqual(
            blueprint.resolvedPrompt(for: project(name: "x-workspace", path: "/Users/me/x")),
            "Set up x-workspace at /Users/me/x, then open x-workspace/api."
        )
    }

    // MARK: - Saving

    func testSavingTwiceUnderOneNameDoesNotOverwriteTheFirst() throws {
        try store.save(Blueprint(
            id: store.availableID(for: "Full stack"), name: "Full stack", prompt: "one"
        ))
        try store.save(Blueprint(
            id: store.availableID(for: "Full stack"), name: "Full stack", prompt: "two"
        ))
        XCTAssertEqual(store.blueprints.map(\.id), ["full-stack", "full-stack-2"])
        XCTAssertEqual(store.blueprint(id: "full-stack")?.prompt, "one")
    }

    /// Editing an existing one keeps its id, so its file is replaced rather
    /// than multiplied.
    func testEditingKeepsTheSameFile() throws {
        try store.save(Blueprint(id: "b", name: "B", prompt: "one"))
        try store.save(Blueprint(id: "b", name: "B renamed", prompt: "two"))
        XCTAssertEqual(store.blueprints.count, 1)
        XCTAssertEqual(store.blueprint(id: "b")?.name, "B renamed")
    }

    func testAnEmptyOrUnusableNameIsRefused() {
        XCTAssertThrowsError(try store.save(Blueprint(id: "x", name: "   ", prompt: "p"))) {
            XCTAssertEqual($0 as? BlueprintError, .emptyName)
        }
        XCTAssertThrowsError(try store.save(Blueprint(id: "x", name: "!!!", prompt: "p"))) {
            XCTAssertEqual($0 as? BlueprintError, .invalidName("!!!"))
        }
    }

    func testAnOverlongPromptIsRefused() {
        let long = String(repeating: "a", count: BlueprintStore.promptLimit + 1)
        XCTAssertThrowsError(try store.save(Blueprint(id: "x", name: "X", prompt: long))) {
            XCTAssertEqual($0 as? BlueprintError, .promptTooLong(BlueprintStore.promptLimit))
        }
    }

    // MARK: - The draft rule

    /// A blueprint is text that later gets fed to an agent, so one an agent
    /// wrote is a draft: it cannot start on its own, whatever it asked for.
    func testAnAgentsBlueprintArrivesAsADraftThatCannotStartItself() throws {
        let saved = try store.save(
            Blueprint(id: "b", name: "B", prompt: "p", startsImmediately: true),
            writtenByAgent: true
        )
        XCTAssertTrue(saved.needsReview)
        XCTAssertFalse(saved.startsImmediately)
    }

    /// Saving from the editor *is* the review, so the mark comes off.
    func testKeepingADraftClearsTheMark() throws {
        try store.save(Blueprint(id: "b", name: "B", prompt: "p"), writtenByAgent: true)
        XCTAssertEqual(store.blueprint(id: "b")?.needsReview, true)

        try store.save(Blueprint(
            id: "b", name: "B", prompt: "p", startsImmediately: true
        ))
        XCTAssertEqual(store.blueprint(id: "b")?.needsReview, false)
        XCTAssertEqual(store.blueprint(id: "b")?.startsImmediately, true)
    }

    // MARK: - Import / export

    func testExportingAndImportingCarriesTheBlueprintAcross() throws {
        try store.save(Blueprint(
            id: "b", name: "Full stack", iconName: "layout-grid",
            prompt: "do the thing", startsImmediately: true
        ))
        let outbox = tempDir.appendingPathComponent("out.md")
        try store.export(id: "b", to: outbox)

        let other = BlueprintStore(
            directory: tempDir.appendingPathComponent("other", isDirectory: true)
        )
        let imported = try other.importBlueprint(from: outbox)
        XCTAssertEqual(imported.name, "Full stack")
        XCTAssertEqual(imported.prompt, "do the thing")
        XCTAssertEqual(imported.iconName, "layout-grid")
        // Someone else's blueprint is treated exactly like an agent's: it does
        // not run before its new owner has read it.
        XCTAssertTrue(imported.needsReview)
        XCTAssertFalse(imported.startsImmediately)
    }

    func testDeletingRemovesTheFile() throws {
        try store.save(Blueprint(id: "b", name: "B", prompt: "p"))
        try store.delete(id: "b")
        XCTAssertTrue(store.blueprints.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "b").path))
        XCTAssertThrowsError(try store.delete(id: "b"))
    }
}
