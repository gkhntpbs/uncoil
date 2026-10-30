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

    /// The caller has to be able to configure what it just created, and a
    /// no-op add has to be distinguishable from a real one.
    func testAddProjectAnswersWithWhatItCreated() throws {
        let store = ProjectStore(directory: tempDir)
        let created = try XCTUnwrap(store.addProject(at: URL(fileURLWithPath: "/tmp/demo")))
        XCTAssertEqual(created.rootPath, "/tmp/demo")
        XCTAssertTrue(store.projects.contains { $0.id == created.id })
        XCTAssertNil(store.addProject(at: URL(fileURLWithPath: "/tmp/demo")))
    }

    /// `sortProjects` keeps the scratch workspace last, so the project that was
    /// just added is not the last one in the list. Reaching for `projects.last`
    /// used to hand the caller Scratch instead.
    func testTheNewProjectIsNotTheLastOneWhenScratchExists() throws {
        let store = ProjectStore(directory: tempDir)
        _ = store.ensureScratchProject()
        let created = try XCTUnwrap(store.addProject(at: URL(fileURLWithPath: "/tmp/real")))
        XCTAssertTrue(store.projects.last?.isScratchWorkspace == true)
        XCTAssertNotEqual(store.projects.last?.id, created.id)
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

    func testLegacySessionArrayMigratesToVersionedDocument() throws {
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let record = SessionRecord(
            projectID: UUID(),
            provider: .claude,
            accountID: nil,
            title: "legacy"
        )
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([record])
        ) as! [[String: Any]]
        object[0].removeValue(forKey: "metadataVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        try legacy.write(to: tempDir.appendingPathComponent("sessions.json"))

        let store = ProjectStore(directory: tempDir)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions[0].metadataVersion,
            ProjectStore.currentSessionSchemaVersion
        )
        let migrated = try JSONDecoder().decode(
            ProjectStore.SessionDocument.self,
            from: Data(contentsOf: tempDir.appendingPathComponent("sessions.json"))
        )
        XCTAssertEqual(
            migrated.schemaVersion,
            ProjectStore.currentSessionSchemaVersion
        )
    }

    func testFutureSessionSchemaIsLoadedWithoutDowngrade() throws {
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let record = SessionRecord(
            projectID: UUID(),
            provider: .claude,
            accountID: nil,
            title: "future"
        )
        let document = ProjectStore.SessionDocument(
            schemaVersion: 99,
            sessions: [record]
        )
        let file = tempDir.appendingPathComponent("sessions.json")
        try JSONEncoder().encode(document).write(to: file)

        let store = ProjectStore(directory: tempDir)

        XCTAssertEqual(store.sessions.map(\.id), [record.id])
        let persisted = try JSONDecoder().decode(
            ProjectStore.SessionDocument.self,
            from: Data(contentsOf: file)
        )
        XCTAssertEqual(persisted.schemaVersion, 99)
    }

    func testClosedSessionHistoryPersistsAndRestartClearsEndState() {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/history"))
        let project = store.projects[0]
        let record = store.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "history"
        )

        store.markSessionEnded(record.id, exitCode: 17)

        XCTAssertTrue(store.activeSessions(for: project.id).isEmpty)
        XCTAssertEqual(store.sessionHistory(for: project.id).map(\.id), [record.id])
        XCTAssertEqual(store.sessionHistory(for: project.id)[0].exitCode, 17)

        let reloaded = ProjectStore(directory: tempDir)
        XCTAssertEqual(reloaded.sessionHistory(for: project.id).map(\.id), [record.id])

        reloaded.markSessionStarted(record.id)

        XCTAssertEqual(reloaded.activeSessions(for: project.id).map(\.id), [record.id])
        XCTAssertNil(reloaded.sessions[0].endedAt)
        XCTAssertEqual(reloaded.sessions[0].restartCount, 1)
    }

    func testProviderSessionIDCanOnlyBeClaimedOnce() {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/claims"))
        let project = store.projects[0]
        let first = store.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "first"
        )
        let second = store.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "second"
        )

        XCTAssertTrue(store.claimProviderSessionID("codex-session", for: first.id))
        XCTAssertFalse(store.claimProviderSessionID("codex-session", for: second.id))
        XCTAssertFalse(store.claimProviderSessionID("other", for: first.id))
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == first.id })?.providerSessionID,
            "codex-session"
        )

        // A bound record is not a candidate for binding, so one still holding a
        // conversation the provider has lost could never learn the id of the
        // session that started in its place — every later launch would ask for
        // the same dead id again.
        store.clearProviderSessionID(first.id)
        XCTAssertNil(store.sessions.first(where: { $0.id == first.id })?.providerSessionID)
        XCTAssertTrue(store.claimProviderSessionID("codex-session-2", for: first.id))
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == first.id })?.providerSessionID,
            "codex-session-2"
        )
    }

    func testCodexSessionLocatorFindsMatchingRecentMetadata() throws {
        let codexHome = tempDir.appendingPathComponent("codex", isDirectory: true)
        // The locator only scans yesterday/today/tomorrow, so the fixture must
        // live under today's date rather than a hardcoded one.
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        let sessionDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true
        )
        let now = CodexSessionLocator.timestampFormatter.string(from: .now)
        let matching = sessionDir.appendingPathComponent("matching.jsonl")
        let other = sessionDir.appendingPathComponent("other.jsonl")
        let matchingLine = """
        {"type":"session_meta","payload":{"id":"match-id","cwd":"/repo/worktree","timestamp":"\(now)"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        """
        let otherLine = """
        {"type":"session_meta","payload":{"id":"other-id","cwd":"/repo/other","timestamp":"\(now)"}}
        """
        try matchingLine.write(to: matching, atomically: true, encoding: .utf8)
        try otherLine.write(to: other, atomically: true, encoding: .utf8)

        let candidates = CodexSessionLocator.candidates(
            codexHome: codexHome,
            cwd: "/repo/worktree",
            startedAfter: Date().addingTimeInterval(-5)
        )

        XCTAssertEqual(candidates.map(\.id), ["match-id"])
    }

    /// The bug this ordering exists for. A thread that another agent is still
    /// writing to in the same directory is modified constantly, so the file
    /// times say nothing about which thread belongs to the session that just
    /// started. Only the thread's own start time does.
    func testTheNewestThreadIsPreferredHoweverTheFilesWereTouched() throws {
        let codexHome = tempDir.appendingPathComponent("codex", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        let sessionDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true
        )
        let format = CodexSessionLocator.timestampFormatter
        let older = format.string(from: Date().addingTimeInterval(-3))
        let newer = format.string(from: Date().addingTimeInterval(-1))
        let olderURL = sessionDir.appendingPathComponent("older.jsonl")
        let newerURL = sessionDir.appendingPathComponent("newer.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"older","cwd":"/repo","timestamp":"\(older)"}}
        """.write(to: olderURL, atomically: true, encoding: .utf8)
        try """
        {"type":"session_meta","payload":{"id":"newer","cwd":"/repo","timestamp":"\(newer)"}}
        """.write(to: newerURL, atomically: true, encoding: .utf8)
        // The long-running one is the most recently *written* file.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: olderURL.path
        )

        let candidates = CodexSessionLocator.candidates(
            codexHome: codexHome,
            cwd: "/repo",
            startedAfter: Date().addingTimeInterval(-10)
        )
        XCTAssertEqual(candidates.map(\.id), ["newer", "older"])
    }

    /// A thread begun before the launch is not this session's, however busy
    /// its file is.
    func testAThreadBegunBeforeTheLaunchIsNotACandidate() throws {
        let codexHome = tempDir.appendingPathComponent("codex", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        let sessionDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true
        )
        let old = CodexSessionLocator.timestampFormatter
            .string(from: Date().addingTimeInterval(-3600))
        let url = sessionDir.appendingPathComponent("live.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"live","cwd":"/repo","timestamp":"\(old)"}}
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )

        XCTAssertTrue(
            CodexSessionLocator.candidates(
                codexHome: codexHome,
                cwd: "/repo",
                startedAfter: Date().addingTimeInterval(-5)
            ).isEmpty
        )
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

    func testLaunchCommandComposition() throws {
        var record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "t")
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record, resume: .fresh(nil), extraArguments: nil
            ),
            "claude"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record, resume: .fresh(nil), extraArguments: "--model opus"
            ),
            "claude --model opus"
        )
        record.providerSessionID = "abc-1"
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record, resume: .resume("abc-1"), extraArguments: " --model opus "
            ),
            "claude --resume 'abc-1' --model opus"
        )
        // The record still carries the id; the decision is what decides. A
        // conversation the provider no longer has must not put a flag on the
        // command line that only ends the session on its first line.
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record, resume: .fresh(.gone), extraArguments: nil
            ),
            "claude"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                binaryPath: "/Users/x/.local/bin/claude",
                resume: .resume("abc-1"),
                extraArguments: nil,
                presetArguments: ["--model", "sonnet"],
                modeArguments: ["--permission-mode", "auto"]
            ),
            "\"/Users/x/.local/bin/claude\" --resume 'abc-1' --permission-mode auto '--model' 'sonnet'"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                resume: .resume("abc-1"),
                extraArguments: nil,
                presetArguments: ["--label", "review'; touch /tmp/unsafe; echo '"]
            ),
            "claude --resume 'abc-1' '--label' 'review'\"'\"'; touch /tmp/unsafe; echo '\"'\"''"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                binaryPath: "/Users/x/.local/bin/claude",
                resume: .resume("abc-1"),
                extraArguments: nil
            ),
            "\"/Users/x/.local/bin/claude\" --resume 'abc-1'"
        )
        let codex = SessionRecord(projectID: UUID(), provider: .codex, accountID: nil, title: "c")
        var resumedCodex = codex
        resumedCodex.providerSessionID = "019efe2f-5276-77c2-bd90-5191ecd4b7a0"
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: resumedCodex,
                binaryPath: "/opt/homebrew/bin/codex",
                resume: .resume("019efe2f-5276-77c2-bd90-5191ecd4b7a0"),
                extraArguments: nil
            ),
            "\"/opt/homebrew/bin/codex\" resume '019efe2f-5276-77c2-bd90-5191ecd4b7a0'"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let toolsContext = String(decoding: try encoder.encode(ProjectContextBuilder.withUncoilTools(nil)), as: UTF8.self)
        let toolsOverride = ("developer_instructions=" + toolsContext).replacingOccurrences(of: "'", with: "'\"'\"'")
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: codex,
                binaryPath: "/opt/homebrew/bin/codex",
                resume: .fresh(nil),
                mcpBinaryPath: "/Volumes/External Disk/Uncoil.app/Contents/Helpers/uncoil-mcp",
                mcpEnvironment: [
                    "UNCOIL_SESSION_ID": "session-1",
                    "UNCOIL_PROJECT_ID": "project-1",
                    "UNCOIL_CONTROL_SOCKET": "/tmp/uncoil.sock",
                ],
                extraArguments: nil
            ),
            "\"/opt/homebrew/bin/codex\" -c '\(toolsOverride)' -c 'mcp_servers.uncoil.command=\"/Volumes/External Disk/Uncoil.app/Contents/Helpers/uncoil-mcp\"' -c 'mcp_servers.uncoil.env.UNCOIL_CONTROL_SOCKET=\"/tmp/uncoil.sock\"' -c 'mcp_servers.uncoil.env.UNCOIL_PROJECT_ID=\"project-1\"' -c 'mcp_servers.uncoil.env.UNCOIL_SESSION_ID=\"session-1\"'"
        )
        let shell = SessionRecord(projectID: UUID(), provider: .terminal, accountID: nil, title: "sh")
        XCTAssertNil(
            TerminalRegistry.launchCommand(
                for: shell, resume: .fresh(nil), extraArguments: "x"
            )
        )
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
        XCTAssertEqual(store.workingMode(for: .claude), .providerDefault)
        XCTAssertEqual(store.workingMode(for: .codex), .providerDefault)
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

    func testWorkingModesPersistPerProvider() {
        let store = SettingsStore(directory: tempDir)
        store.setWorkingMode(.auto, for: .claude)
        store.setWorkingMode(.fullAccess, for: .codex)

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.workingMode(for: .claude), .auto)
        XCTAssertEqual(reloaded.workingMode(for: .codex), .fullAccess)
        XCTAssertEqual(
            reloaded.workingModeArguments(for: .claude),
            ["--permission-mode", "auto"]
        )
        XCTAssertEqual(
            reloaded.workingModeArguments(for: .codex),
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        )
    }

    func testSessionQuitBehaviorDefaultsToKeepRunningAndPersists() {
        let store = SettingsStore(directory: tempDir)
        XCTAssertEqual(store.sessionQuitBehavior, .keepSessionsRunning)

        store.setSessionQuitBehavior(.terminateAllAgents)

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.sessionQuitBehavior, .terminateAllAgents)
        XCTAssertEqual(
            ApplicationLifecycle.shared.sessionQuitBehavior,
            .terminateAllAgents
        )
    }

    /// The preset editor is gone — a preset is a role in code, not something a
    /// user should have to design — but a list written by an older build is
    /// still read and still honoured, so nobody's `create_child` setup changes
    /// under them.
    func testAPresetListWrittenByAnOlderBuildIsStillHonoured() {
        let store = SettingsStore(directory: tempDir)
        let preset = SessionPreset(
            id: "review",
            name: "Review",
            provider: .codex,
            extraArguments: ["--model", "gpt-5"],
            initialPromptTemplate: "Review the change",
            grantedCapabilities: ["sessions.read", "artifacts.read"],
            permissionMode: "standard"
        )
        store.configuredPresets = [preset]
        store.save()

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.preset(id: "review"), preset)
        XCTAssertEqual(reloaded.presets, [preset])
    }

    /// With nothing on disk, the built-in roles are the whole model.
    func testWithNoConfiguredListThePresetsAreTheBuiltInRoles() {
        let store = SettingsStore(directory: tempDir)
        XCTAssertEqual(store.presets, SessionPreset.builtInDefaults)
    }

    func testTranscriptRetentionDefaultsDisabledAndPersists() {
        let store = SettingsStore(directory: tempDir)
        XCTAssertEqual(store.transcriptRetentionPolicy, .disabled)

        store.setTranscriptRetentionPolicy(.thirtyDays)

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.transcriptRetentionPolicy, .thirtyDays)
    }

    func testTranscriptStoreHonorsPolicyPrunesAndClears() throws {
        let transcriptStore = SessionTranscriptStore(dataDirectory: tempDir)
        let disabledID = UUID()
        transcriptStore.append(
            Data("secret-disabled".utf8),
            sessionID: disabledID,
            policy: .disabled
        )
        XCTAssertNil(transcriptStore.data(for: disabledID))

        let retainedID = UUID()
        transcriptStore.append(
            Data("secret-retained".utf8),
            sessionID: retainedID,
            policy: .sevenDays
        )
        XCTAssertEqual(
            String(data: transcriptStore.data(for: retainedID)!, encoding: .utf8),
            "secret-retained"
        )
        let file = tempDir
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("\(retainedID.uuidString).log")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: file.path
        )

        transcriptStore.prune(policy: .sevenDays)
        XCTAssertNil(transcriptStore.data(for: retainedID))

        transcriptStore.append(
            Data("secret-clear".utf8),
            sessionID: retainedID,
            policy: .forever
        )
        XCTAssertTrue(transcriptStore.containsTranscripts())
        transcriptStore.clearAll()
        XCTAssertFalse(transcriptStore.containsTranscripts())
    }

    func testUnsupportedWorkingModeIsIgnored() {
        let store = SettingsStore(directory: tempDir)
        store.setWorkingMode(.plan, for: .codex)
        XCTAssertEqual(store.workingMode(for: .codex), .providerDefault)
    }

    /// Uncoil adds no flag it was not asked for, and that has to include the
    /// flags nobody asked for by default. Before this, every Codex launch
    /// carried `--sandbox` and `--ask-for-approval` whether or not the user
    /// had ever opened the setting, so whatever they had configured in
    /// `~/.codex/config.toml` was overruled on every launch.
    func testAnUntouchedProviderAddsNoModeFlags() {
        let store = SettingsStore(directory: tempDir)
        for provider in AgentProvider.agents {
            XCTAssertEqual(
                store.workingMode(for: provider), .providerDefault, provider.rawValue
            )
            XCTAssertTrue(
                store.workingModeArguments(for: provider).isEmpty, provider.rawValue
            )
        }
    }

    func testAChosenModeIsKeptAndUsed() {
        let store = SettingsStore(directory: tempDir)
        store.setWorkingMode(.readOnly, for: .codex)
        XCTAssertEqual(store.workingMode(for: .codex), .readOnly)
        XCTAssertEqual(
            store.workingModeArguments(for: .codex),
            ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        )
    }

    func testWorkingModeOptionsAndArgumentsMatchProviders() {
        XCTAssertEqual(
            AgentWorkingMode.options(for: .claude),
            [.providerDefault, .manual, .acceptEdits, .plan, .auto, .dangerouslySkipPermissions]
        )
        XCTAssertEqual(
            AgentWorkingMode.options(for: .codex),
            [.providerDefault, .readOnly, .askForApproval, .approveForMe, .fullAccess]
        )
        // Read-only used to be normalised into Codex's workspace-write, which
        // is to say the one mode that promises not to write was the one that
        // could. It is its own mode now, and it is not mapped onto anything.
        XCTAssertEqual(AgentWorkingMode.readOnly.normalized(for: .codex), .readOnly)
        XCTAssertEqual(
            AgentWorkingMode.readOnly.launchArguments(for: .codex),
            ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        )
        // The provider's own default adds nothing, for every provider.
        for provider in AgentProvider.allCases {
            XCTAssertEqual(
                AgentWorkingMode.providerDefault.normalized(for: provider),
                .providerDefault,
                provider.rawValue
            )
            XCTAssertTrue(
                AgentWorkingMode.providerDefault.launchArguments(for: provider).isEmpty,
                provider.rawValue
            )
        }
        XCTAssertEqual(
            AgentWorkingMode.dangerouslySkipPermissions.launchArguments(for: .claude),
            ["--dangerously-skip-permissions"]
        )
        XCTAssertEqual(
            AgentWorkingMode.askForApproval.launchArguments(for: .codex),
            ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        )
        XCTAssertEqual(
            AgentWorkingMode.approveForMe.launchArguments(for: .codex),
            ["--approve-for-me"]
        )
        XCTAssertEqual(
            AgentWorkingMode.fullAccess.launchArguments(for: .codex),
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        )
    }
}

@MainActor
final class ProjectStoreActivityTests: XCTestCase {
    func testActivityIsStampedAtMostOncePerResolution() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncoil-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        let record = store.createSession(projectID: store.projects[0].id, provider: .claude, accountID: nil, title: "t")
        let start = record.lastActivityAt.addingTimeInterval(60)

        store.noteActivity(record.id, at: start)
        XCTAssertEqual(store.sessions.first?.lastActivityAt, start)

        store.noteActivity(record.id, at: start.addingTimeInterval(5))
        XCTAssertEqual(store.sessions.first?.lastActivityAt, start, "a burst of events writes once")

        let later = start.addingTimeInterval(ProjectStore.activityResolution)
        store.noteActivity(record.id, at: later)
        XCTAssertEqual(store.sessions.first?.lastActivityAt, later)
    }
}
