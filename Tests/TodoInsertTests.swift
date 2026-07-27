import XCTest
@testable import Uncoil

/// Adding a task from the UI: the new line matches its siblings and the rest of
/// the file stays byte-identical.
final class TodoInsertTests: XCTestCase {
    private func parse(_ raw: String) -> TaskDocument {
        TodoParser.parse(raw, path: "/tmp/TODO.md")
    }

    func testTheNewLineMatchesItsSiblingsStyle() throws {
        let raw = """
        # Plan

        ## Arayüz
        - [ ] eski görev
        """
        let document = parse(raw)
        let patch = try TodoEditor.insertTaskPatch(
            text: "yeni görev", under: ["Plan", "Arayüz"], in: document
        )
        let result = try TodoEditor.apply([patch], to: raw)
        XCTAssertEqual(result, raw + "\n- [ ] yeni görev\n")
    }

    /// An ordered sibling gets the next number, not a duplicate of the same one.
    func testAnOrderedSiblingGetsTheNextNumber() throws {
        let raw = """
        ## Sıra
        1. [ ] birinci
        2. [x] ikinci
        """
        let document = parse(raw)
        let patch = try TodoEditor.insertTaskPatch(
            text: "üçüncü", under: ["Sıra"], in: document
        )
        let result = try TodoEditor.apply([patch], to: raw)
        XCTAssertTrue(result.hasSuffix("3. [ ] üçüncü\n"), result)
    }

    func testAnIndentedSiblingKeepsItsIndent() throws {
        let raw = """
        ## Grup
        - [ ] üst
          * [ ] alt
        """
        let document = parse(raw)
        // Siblings under the heading include the nested one; the last sibling's
        // indent and marker are what the new line copies.
        let patch = try TodoEditor.insertTaskPatch(
            text: "yeni", under: ["Grup"], in: document
        )
        let result = try TodoEditor.apply([patch], to: raw)
        XCTAssertTrue(result.hasSuffix("  * [ ] yeni\n"), result)
    }

    /// First task under a bare heading: a blank line separates it from the
    /// heading, the way a person or an agent would write it.
    func testTheFirstTaskUnderAHeadingGetsABlankLine() throws {
        let raw = """
        # Plan

        ## Boş başlık
        """
        let document = parse(raw)
        let patch = try TodoEditor.insertTaskPatch(
            text: "ilk görev", under: ["Plan", "Boş başlık"], in: document
        )
        let result = try TodoEditor.apply([patch], to: raw)
        XCTAssertTrue(result.contains("## Boş başlık\n\n- [ ] ilk görev\n"), result)
        // Everything before the insertion point is untouched.
        XCTAssertTrue(result.hasPrefix(raw), result)
    }

    func testInsertingAtTheRootOfAHeadinglessFile() throws {
        let raw = "- [ ] tek görev"
        let document = parse(raw)
        let patch = try TodoEditor.insertTaskPatch(text: "iki", under: [], in: document)
        let result = try TodoEditor.apply([patch], to: raw)
        // The old last line had no newline; the paste brings the separator.
        XCTAssertEqual(result, "- [ ] tek görev\n- [ ] iki\n")
    }

    func testAnUnknownHeadingAndEmptyTextAreRefused() {
        let document = parse("# A\n- [ ] x\n")
        XCTAssertThrowsError(try TodoEditor.insertTaskPatch(
            text: "y", under: ["Yok Böyle Başlık"], in: document
        ))
        XCTAssertThrowsError(try TodoEditor.insertTaskPatch(
            text: "   \n ", under: [], in: document
        ))
    }

    func testNextListMarker() {
        XCTAssertEqual(TodoEditor.nextListMarker(after: "-"), "-")
        XCTAssertEqual(TodoEditor.nextListMarker(after: "*"), "*")
        XCTAssertEqual(TodoEditor.nextListMarker(after: "3."), "4.")
        XCTAssertEqual(TodoEditor.nextListMarker(after: "7)"), "8)")
    }

    /// The whole point: after the insert, the file reparses and the new task is
    /// a first-class citizen of its heading.
    func testTheInsertedTaskParsesBackUnderItsHeading() throws {
        let raw = """
        # Plan

        ## Arayüz
        - [ ] eski
        """
        let document = parse(raw)
        let patch = try TodoEditor.insertTaskPatch(
            text: "yeni", under: ["Plan", "Arayüz"], in: document
        )
        let reparsed = parse(try TodoEditor.apply([patch], to: raw))
        XCTAssertEqual(
            reparsed.tasks(under: ["Plan", "Arayüz"]).map(\.text),
            ["eski", "yeni"]
        )
    }
}

/// The starter file, and the offer the project screen makes once per project.
final class TodoStarterTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-todo-starter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreateWritesAParsableStarter() throws {
        let result = TodoStarter.create(in: directory.path)
        guard case .success(let path) = result else { return XCTFail("expected a file") }

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let document = TodoParser.parse(raw, path: path)
        XCTAssertEqual(document.openTasks.count, 3, "the starter must read back as real tasks")
    }

    func testCreateRefusesToTouchAnExistingFile() throws {
        let url = directory.appendingPathComponent("TODO.md")
        try Data("mine\n".utf8).write(to: url)

        XCTAssertEqual(TodoStarter.create(in: directory.path), .failure(.alreadyExists))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")
    }

    func testHintDismissalIsPerProjectAndSticks() {
        let suite = "uncoil-todo-hint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let mine = UUID()
        let other = UUID()
        XCTAssertFalse(TodoHintDismissal.isDismissed(mine, defaults: defaults))

        TodoHintDismissal.dismiss(mine, defaults: defaults)
        XCTAssertTrue(TodoHintDismissal.isDismissed(mine, defaults: defaults))
        XCTAssertFalse(TodoHintDismissal.isDismissed(other, defaults: defaults),
                       "one project's answer must not speak for another")

        // A fresh read of the same defaults is what a relaunch does.
        XCTAssertTrue(TodoHintDismissal.isDismissed(mine, defaults: UserDefaults(suiteName: suite)!))
    }
}
