import XCTest
@testable import Uncoil

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testProjectsAndSessionsPersistAcrossReload() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo-project"))
        let project = store.projects[0]
        store.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "claude: ilk")

        let reloaded = ProjectStore(directory: tempDir)
        XCTAssertEqual(reloaded.projects, store.projects)
        XCTAssertEqual(reloaded.sessions(for: project.id).count, 1)
        XCTAssertEqual(reloaded.sessions(for: project.id)[0].provider, .claude)
    }

    func testDuplicatePathIgnored() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        XCTAssertEqual(store.projects.count, 1)
    }

    func testRemoveProjectRemovesItsSessions() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let project = store.projects[0]
        store.createSession(projectID: project.id, provider: .codex, accountID: nil, title: "codex")
        store.removeProject(project)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testAttentionPriorityOrdering() {
        XCTAssertGreaterThan(
            AgentSessionStatus.waitingForPermission.attentionPriority,
            AgentSessionStatus.running.attentionPriority
        )
        XCTAssertGreaterThan(
            AgentSessionStatus.waitingForInput.attentionPriority,
            AgentSessionStatus.running.attentionPriority
        )
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-settings-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDefaultAccountsCreatedOnFirstRun() {
        let store = SettingsStore(directory: tempDir)
        XCTAssertEqual(store.accounts(for: .claude).count, 1)
        XCTAssertEqual(store.accounts(for: .codex).count, 1)
        XCTAssertNil(store.accounts(for: .claude)[0].directoryName)
    }

    func testAddedAccountGetsIsolatedConfigDirAndPersists() {
        let store = SettingsStore(directory: tempDir)
        let profile = store.addAccount(provider: .claude, name: "İş Hesabı")
        XCTAssertEqual(profile.directoryName, "i̇ş-hesabı".filter { $0.isLetter || $0.isNumber || $0 == "-" })
        let dir = profile.configDirectory(profilesRoot: store.profilesRootURL)
        XCTAssertNotNil(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir!.path))

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertTrue(reloaded.accounts(for: .claude).contains { $0.name == "İş Hesabı" })
    }

    func testDefaultAccountSelectionPersists() {
        let store = SettingsStore(directory: tempDir)
        let work = store.addAccount(provider: .claude, name: "Work")
        store.setDefaultAccount(work)
        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.defaultAccount(for: .claude)?.id, work.id)
    }

    func testDefaultProfileCannotBeRemoved() {
        let store = SettingsStore(directory: tempDir)
        let base = store.accounts(for: .claude)[0]
        store.removeAccount(base)
        XCTAssertEqual(store.accounts(for: .claude).count, 1)
    }
}
