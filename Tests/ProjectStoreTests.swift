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

    func testWorktreeSessionPersistsWorkingDirectory() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let project = store.projects[0]
        store.createSession(
            projectID: project.id,
            provider: .claude,
            accountID: nil,
            title: "wt",
            worktreePath: "/tmp/demo/.uncoil-worktrees/fix-login"
        )
        let reloaded = ProjectStore(directory: tempDir)
        let record = reloaded.sessions(for: project.id)[0]
        XCTAssertEqual(record.workingDirectory(in: project), "/tmp/demo/.uncoil-worktrees/fix-login")
    }

    func testSessionGroupsPersistAndAssignMultipleSessions() {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let project = store.projects[0]
        let first = store.createSession(
            projectID: project.id,
            provider: .claude,
            accountID: nil,
            title: "first"
        )
        let second = store.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "second"
        )
        let group = store.createGroup(projectID: project.id, name: "Implementation")
        XCTAssertNotNil(group)
        store.assignSessions([first.id, second.id], to: group?.id)

        let reloaded = ProjectStore(directory: tempDir)
        XCTAssertEqual(reloaded.groups(for: project.id).map(\.name), ["Implementation"])
        XCTAssertEqual(Set(reloaded.sessions(in: group!.id).map(\.id)), [first.id, second.id])

        reloaded.removeGroup(group!.id)
        XCTAssertTrue(reloaded.sessionGroups.isEmpty)
        XCTAssertTrue(reloaded.sessions.allSatisfy { $0.groupID == nil })
    }

    func testBulkSessionRemoval() {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let project = store.projects[0]
        let first = store.createSession(
            projectID: project.id,
            provider: .claude,
            accountID: nil,
            title: "first"
        )
        let second = store.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "second"
        )
        store.removeSessions([first.id, second.id])
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testWorktreePorcelainParsing() {
        let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /repo/.uncoil-worktrees/fix-login
        HEAD def
        branch refs/heads/uncoil/fix-login

        worktree /repo/.uncoil-worktrees/spike
        HEAD 123
        detached
        """
        let trees = GitService.parseWorktrees(porcelain, mainPath: "/repo")
        XCTAssertEqual(trees.count, 3)
        XCTAssertTrue(trees[0].isMain)
        XCTAssertEqual(trees[1].branch, "uncoil/fix-login")
        XCTAssertFalse(trees[1].isMain)
        XCTAssertNil(trees[2].branch)
    }

    func testLaunchCommandComposition() {
        var record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "t")
        XCTAssertEqual(TerminalRegistry.launchCommand(for: record, extraArguments: nil), "claude")
        XCTAssertEqual(
            TerminalRegistry.launchCommand(for: record, extraArguments: "--model opus"),
            "claude --model opus"
        )
        record.providerSessionID = "abc-1"
        XCTAssertEqual(
            TerminalRegistry.launchCommand(for: record, extraArguments: " --model opus "),
            "claude --resume abc-1 --model opus"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                binaryPath: "/Users/x/.local/bin/claude",
                extraArguments: nil
            ),
            "\"/Users/x/.local/bin/claude\" --resume abc-1"
        )
        let shell = SessionRecord(projectID: UUID(), provider: .terminal, accountID: nil, title: "sh")
        XCTAssertNil(TerminalRegistry.launchCommand(for: shell, extraArguments: "x"))
    }

    func testGitHubRepoSlugParsing() {
        XCTAssertEqual(
            GitHubService.repoSlug(fromRemoteURL: "git@github.com:gkhntpbs/uncoil.git"),
            "gkhntpbs/uncoil"
        )
        XCTAssertEqual(
            GitHubService.repoSlug(fromRemoteURL: "https://github.com/owner/repo"),
            "owner/repo"
        )
        XCTAssertNil(GitHubService.repoSlug(fromRemoteURL: "https://gitlab.com/x/y.git"))
    }

    func testPullRequestParsing() {
        let items: [[String: Any]] = [
            [
                "id": 1, "number": 42, "title": "Fix login",
                "user": ["login": "gkhntpbs"], "draft": true,
                "html_url": "https://github.com/o/r/pull/42",
            ],
            ["id": 2, "title": "missing number"],
        ]
        let prs = GitHubService.parsePullRequests(items)
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].number, 42)
        XCTAssertEqual(prs[0].author, "gkhntpbs")
        XCTAssertTrue(prs[0].isDraft)
    }

    func testProjectCustomizationPersists() {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let id = store.projects[0].id
        store.updateProject(id) { project in
            project.iconName = "rocket"
            project.colorHex = 0xE2572B
            project.name = "Roket"
        }
        let reloaded = ProjectStore(directory: tempDir)
        XCTAssertEqual(reloaded.projects[0].iconName, "rocket")
        XCTAssertEqual(reloaded.projects[0].colorHex, 0xE2572B)
        XCTAssertEqual(reloaded.projects[0].name, "Roket")
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
