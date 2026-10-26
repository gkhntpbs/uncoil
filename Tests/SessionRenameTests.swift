import XCTest
@testable import Uncoil

/// A session's name is the user's once they type one: automatic titling only
/// ever replaces a placeholder, and clearing the name hands it back.
@MainActor
final class SessionRenameTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private var projectID: UUID!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSessionRename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(directory: root)
        let path = root.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        store.addProject(at: path)
        projectID = store.projects[0].id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ provider: AgentProvider, _ title: String) -> UUID {
        store.createSession(projectID: projectID, provider: provider, accountID: nil, title: title).id
    }

    private func title(_ id: UUID) -> String? { store.sessions.first { $0.id == id }?.title }

    func testRenameTrimsAndSurvivesAutomaticTitle() {
        let id = make(.claude, "claude: new session")
        store.renameSession(id, to: "  Auth refactor \n")
        XCTAssertEqual(title(id), "Auth refactor")
        store.adoptAutomaticTitle("fix the login bug", for: id)
        XCTAssertEqual(title(id), "Auth refactor")
    }

    func testRenamePersistsAcrossReload() {
        let id = make(.claude, "claude: new session")
        store.renameSession(id, to: "Release prep")
        let reloaded = ProjectStore(directory: root)
        XCTAssertEqual(reloaded.sessions.first { $0.id == id }?.title, "Release prep")
    }

    func testEmptyNameRestoresAutomaticNaming() {
        let agent = make(.claude, "something")
        store.renameSession(agent, to: "   ")
        XCTAssertEqual(title(agent), "claude: new session")
        store.adoptAutomaticTitle("next prompt", for: agent)
        XCTAssertEqual(title(agent), "next prompt")

        let shell = make(.terminal, "named shell")
        store.renameSession(shell, to: "")
        XCTAssertEqual(title(shell), "terminal")
    }
}
