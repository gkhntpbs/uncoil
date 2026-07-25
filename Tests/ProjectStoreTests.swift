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
    }

    func testCodexSessionLocatorFindsMatchingRecentMetadata() throws {
        let codexHome = tempDir.appendingPathComponent("codex", isDirectory: true)
        let sessionDir = codexHome
            .appendingPathComponent("sessions/2026/07/25", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true
        )
        let matching = sessionDir.appendingPathComponent("matching.jsonl")
        let other = sessionDir.appendingPathComponent("other.jsonl")
        let matchingLine = """
        {"type":"session_meta","payload":{"id":"match-id","cwd":"/repo/worktree"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        """
        let otherLine = """
        {"type":"session_meta","payload":{"id":"other-id","cwd":"/repo/other"}}
        """
        try matchingLine.write(to: matching, atomically: true, encoding: .utf8)
        try otherLine.write(to: other, atomically: true, encoding: .utf8)

        let candidates = CodexSessionLocator.candidates(
            codexHome: codexHome,
            cwd: "/repo/worktree",
            modifiedAfter: Date().addingTimeInterval(-5)
        )

        XCTAssertEqual(candidates.map(\.id), ["match-id"])
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
            "claude --resume 'abc-1' --model opus"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                binaryPath: "/Users/x/.local/bin/claude",
                extraArguments: nil,
                presetArguments: ["--model", "sonnet"],
                modeArguments: ["--permission-mode", "auto"]
            ),
            "\"/Users/x/.local/bin/claude\" --resume 'abc-1' --permission-mode auto '--model' 'sonnet'"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                extraArguments: nil,
                presetArguments: ["--label", "review'; touch /tmp/unsafe; echo '"]
            ),
            "claude --resume 'abc-1' '--label' 'review'\"'\"'; touch /tmp/unsafe; echo '\"'\"''"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: record,
                binaryPath: "/Users/x/.local/bin/claude",
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
                extraArguments: nil
            ),
            "\"/opt/homebrew/bin/codex\" resume '019efe2f-5276-77c2-bd90-5191ecd4b7a0'"
        )
        XCTAssertEqual(
            TerminalRegistry.launchCommand(
                for: codex,
                binaryPath: "/opt/homebrew/bin/codex",
                mcpBinaryPath: "/Volumes/External Disk/Uncoil.app/Contents/Helpers/uncoil-mcp",
                mcpEnvironment: [
                    "UNCOIL_SESSION_ID": "session-1",
                    "UNCOIL_PROJECT_ID": "project-1",
                    "UNCOIL_CONTROL_SOCKET": "/tmp/uncoil.sock",
                ],
                extraArguments: nil
            ),
            "\"/opt/homebrew/bin/codex\" -c 'mcp_servers.uncoil.command=\"/Volumes/External Disk/Uncoil.app/Contents/Helpers/uncoil-mcp\"' -c 'mcp_servers.uncoil.env.UNCOIL_CONTROL_SOCKET=\"/tmp/uncoil.sock\"' -c 'mcp_servers.uncoil.env.UNCOIL_PROJECT_ID=\"project-1\"' -c 'mcp_servers.uncoil.env.UNCOIL_SESSION_ID=\"session-1\"'"
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
        XCTAssertEqual(store.workingMode(for: .claude), .manual)
        XCTAssertEqual(store.workingMode(for: .codex), .askForApproval)
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

    func testSessionPresetEditorOperationsPersist() {
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

        store.upsertPreset(preset)
        XCTAssertEqual(store.preset(id: "review"), preset)

        let reloaded = SettingsStore(directory: tempDir)
        XCTAssertEqual(reloaded.preset(id: "review"), preset)

        reloaded.removePreset(id: "review")
        XCTAssertNil(reloaded.preset(id: "review"))

        reloaded.resetPresets()
        XCTAssertEqual(reloaded.presets, SessionPreset.builtInDefaults)
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
        XCTAssertEqual(store.workingMode(for: .codex), .askForApproval)
    }

    func testWorkingModeOptionsAndArgumentsMatchProviders() {
        XCTAssertEqual(
            AgentWorkingMode.options(for: .claude),
            [.manual, .acceptEdits, .plan, .auto, .dangerouslySkipPermissions]
        )
        XCTAssertEqual(
            AgentWorkingMode.options(for: .codex),
            [.askForApproval, .approveForMe, .fullAccess]
        )
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
            ["--sandbox", "workspace-write", "--ask-for-approval", "never"]
        )
        XCTAssertEqual(
            AgentWorkingMode.fullAccess.launchArguments(for: .codex),
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        )
    }
}
