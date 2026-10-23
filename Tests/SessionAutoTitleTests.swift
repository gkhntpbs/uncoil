import XCTest
@testable import Uncoil

/// Naming a session after its first prompt: what counts as a title, and what
/// the app can pick out of raw keystrokes.
final class SessionAutoTitleTests: XCTestCase {
    private func feed(_ text: String) -> String? {
        var buffer = SessionAutoTitle.TypedLineBuffer()
        return buffer.feed(Array(text.utf8))
    }

    // MARK: - The candidate

    func testFirstLineBecomesTheTitle() {
        XCTAssertEqual(
            SessionAutoTitle.candidate(from: "  fix the sidebar order\nand then rest  "),
            "fix the sidebar order"
        )
    }

    func testEmptyPromptNamesNothing() {
        XCTAssertNil(SessionAutoTitle.candidate(from: "   \n\n"))
        XCTAssertNil(SessionAutoTitle.candidate(from: ""))
    }

    func testALongLineIsTruncatedWithAnEllipsis() {
        let title = SessionAutoTitle.candidate(from: String(repeating: "a", count: 200))
        XCTAssertEqual(title?.count, SessionAutoTitle.maxLength)
        XCTAssertEqual(title?.last, "…")
    }

    func testASlashCommandKeepsItsName() {
        XCTAssertEqual(SessionAutoTitle.candidate(from: "/release 0.2.0"), "/release 0.2.0")
    }

    // MARK: - The keystroke buffer

    func testALineIsReturnedOnlyWhenReturnIsPressed() {
        var buffer = SessionAutoTitle.TypedLineBuffer()
        XCTAssertNil(buffer.feed(Array("fix the ".utf8)))
        XCTAssertNil(buffer.feed(Array("order".utf8)))
        XCTAssertEqual(buffer.feed([0x0D]), "fix the order")
    }

    func testArrowKeysAndOtherEscapesStayOutOfTheTitle() {
        XCTAssertEqual(feed("ab\u{1B}[Ac\u{1B}[1;2Dd\r"), "abcd")
    }

    func testBackspaceRemovesAWholeCharacterNotAByte() {
        XCTAssertEqual(feed("kağıt\u{7F}\r"), "kağı")
        XCTAssertEqual(feed("ab\u{08}c\r"), "ac")
    }

    func testBackspaceOnAnEmptyLineIsHarmless() {
        XCTAssertEqual(feed("\u{7F}\u{7F}ok\r"), "ok")
    }

    func testAnAbandonedLineNamesNothing() {
        XCTAssertNil(feed("half a thought\u{03}"))
        XCTAssertEqual(feed("half a thought\u{03}the real one\r"), "the real one")
        XCTAssertEqual(feed("erase me\u{15}this one\r"), "this one")
    }

    func testAnEmptyReturnNamesNothing() {
        XCTAssertNil(feed("\r"))
        XCTAssertNil(feed("   \r"))
    }

    func testTheBufferStartsOverAfterALine() {
        var buffer = SessionAutoTitle.TypedLineBuffer()
        XCTAssertEqual(buffer.feed(Array("first\r".utf8)), "first")
        XCTAssertEqual(buffer.feed(Array("second\r".utf8)), "second")
    }

    func testAPasteLongerThanAnyTitleStillNamesTheSession() {
        let paste = String(repeating: "x", count: SessionAutoTitle.TypedLineBuffer.byteLimit * 2)
        let title = feed(paste + "\r")
        XCTAssertEqual(title?.count, SessionAutoTitle.maxLength)
    }
}

/// The store side: the name is taken once and never taken back.
@MainActor
final class SessionAutomaticTitleStoreTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private var projectID: UUID!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilAutoTitle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(directory: root)
        store.addProject(at: root.appendingPathComponent("alpha", isDirectory: true))
        projectID = store.projects[0].id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(titled title: String) -> UUID {
        store.createSession(
            projectID: projectID, provider: .claude, accountID: nil, title: title
        ).id
    }

    private func title(of id: UUID) -> String? {
        store.sessions.first { $0.id == id }?.title
    }

    func testAPlaceholderTitleIsReplacedByTheFirstPrompt() {
        let id = makeSession(titled: "claude: new session")
        store.adoptAutomaticTitle("fix the sidebar order", for: id)
        XCTAssertEqual(title(of: id), "fix the sidebar order")
    }

    func testASessionIsNamedOnceAndKeepsThatName() {
        let id = makeSession(titled: "claude: new session")
        store.adoptAutomaticTitle("the first thing", for: id)
        store.adoptAutomaticTitle("the second thing", for: id)
        XCTAssertEqual(title(of: id), "the first thing")
    }

    func testATitleThatMeansSomethingIsLeftAlone() {
        let id = makeSession(titled: "#42 the release blocker")
        store.adoptAutomaticTitle("something else entirely", for: id)
        XCTAssertEqual(title(of: id), "#42 the release blocker")
    }

    // MARK: Terminal replies and the kitty keyboard protocol

    private func typed(_ text: String) -> String? {
        var buffer = SessionAutoTitle.TypedLineBuffer()
        return buffer.feed(Array(text.utf8))
    }

    func testColourQueryRepliesStayOutOfTheTitle() {
        // What SwiftTerm answers Codex's OSC 10/11 colour queries with.
        let reply = "\u{1B}]10;rgb:e9e9/e9e9/ecec\u{1B}\\\u{1B}]11;rgb:0f0f/0f0f/1111\u{07}"
        XCTAssertEqual(typed(reply + "fix the build\r"), "fix the build")
        XCTAssertEqual(typed("\u{1B}[1;1R\u{1B}[?62;22c\u{1B}[?7ufix it\r"), "fix it")
    }

    func testKittyEncodedShiftedKeysKeepTheirCharacter() {
        // A Turkish layout: `/` is Shift+7, sent as CSI 55:47;2u.
        XCTAssertEqual(typed("\u{1B}[55:47;2ureview\r"), "/review")
        XCTAssertEqual(typed("\u{1B}[102:70;2uix \u{1B}[105;2u\r"), "Fix I")
        // Releases add nothing; text the terminal spelled out is taken as is.
        XCTAssertEqual(typed("a\u{1B}[97;1:3ub\u{1B}[351;1;351u\r"), "abş")
        // Disambiguated Ctrl-C still abandons the line.
        XCTAssertNil(typed("oops\u{1B}[99;5u\r"))
    }

    func testABareSlashCommandDoesNotNameTheSession() {
        var buffer = SessionAutoTitle.TypedLineBuffer()
        XCTAssertNil(buffer.feed(Array("/model\r".utf8)))
        XCTAssertEqual(buffer.feed(Array("add a login screen\r".utf8)), "add a login screen")
    }

    func testATerminalReplyTitleIsRecognised() {
        XCTAssertTrue(SessionAutoTitle.isTerminalReply("10;rgb:e9e9/e9e9/ecec11;rgb:0f0f/0f0f/1111"))
        XCTAssertTrue(SessionAutoTitle.isTerminalReply("10;rgb:e9e9/e9e9/ecec11;rgb:0f0f/0f0f/111…"))
        XCTAssertFalse(SessionAutoTitle.isTerminalReply("fix rgb: colour parsing"))
    }
}
