import XCTest
@testable import Uncoil

@MainActor
final class TasksHandlerTests: XCTestCase {
    private var dataDir: URL!
    private var projectRoot: URL!
    private var store: ProjectStore!
    private var sessionStore: SessionStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-tasks-mcp-\(UUID().uuidString)", isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-tasks-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projectRoot = root.resolvingSymlinksInPath()
        try write("""
        # Aşama 1

        ## Todo

        - [ ] ilk görev
          açıklama satırı
          - [ ] alt görev
        - [ ] ikinci görev

        ## Done

        - [x] bitmiş görev
        """)

        store = ProjectStore(directory: dataDir)
        sessionStore = SessionStore()
        store.addProject(at: projectRoot)
        let project = store.projects[0]
        caller = store.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: x"
        )
        router = CapabilityRouter(
            projectStore: store, sessionStore: sessionStore,
            audit: AuditLog(dataDirectory: dataDir), dataDirectory: dataDir
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private func write(_ contents: String) throws {
        try Data(contents.utf8).write(
            to: projectRoot.appendingPathComponent("TODO.md"), options: .atomic
        )
    }

    private func read() throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent("TODO.md"), encoding: .utf8)
    }

    private func call(
        _ action: String,
        _ args: [String: JSONValue] = [:],
        capabilities: [String]? = nil
    ) async -> ControlEnvelope {
        if let capabilities {
            store.updateSession(caller.id) { $0.capabilities = capabilities }
            caller = store.sessions.first { $0.id == caller.id }
        }
        return await router.handle(ControlRequest(
            capability: "uncoil_tasks", action: action, args: args,
            caller_session_id: caller.id.uuidString
        ))
    }

    private func taskID(_ text: String) async throws -> String {
        let envelope = await call("list_tasks")
        let tasks = try XCTUnwrap(envelope.data?.objectValue?["tasks"]?.arrayValue)
        let match = tasks.first { $0.objectValue?["text"]?.stringValue == text }
        return try XCTUnwrap(match?.objectValue?["task_id"]?.stringValue)
    }

    // MARK: - Read

    func testListsTodoFilesAndTasks() async throws {
        let files = await call("list_todo_files")
        XCTAssertTrue(files.ok)
        XCTAssertEqual(files.data?.objectValue?["todo_files"]?.arrayValue?.count, 1)

        let tasks = await call("list_tasks")
        XCTAssertEqual(tasks.data?.objectValue?["total"]?.intValue, 4)
        XCTAssertEqual(tasks.data?.objectValue?["truncated"]?.boolValue, false)
    }

    func testListTasksReportsWhenItTruncates() async throws {
        let tasks = await call("list_tasks", ["limit": .int(1)])
        XCTAssertEqual(tasks.data?.objectValue?["tasks"]?.arrayValue?.count, 1)
        XCTAssertEqual(
            tasks.data?.objectValue?["truncated"]?.boolValue, true,
            "a cap is always reported, never silent"
        )
    }

    func testGetTaskAndContextCarryTheRealBlockAndRules() async throws {
        let id = try await taskID("ilk görev")
        let task = await call("get_task", ["task_id": .string(id)])
        XCTAssertTrue(task.data?.objectValue?["raw_block"]?.stringValue?.contains("açıklama satırı") ?? false)
        XCTAssertEqual(task.data?.objectValue?["subtask_ids"]?.arrayValue?.count, 1)

        let context = await call("get_task_context", ["task_id": .string(id), "role": .string("reviewer")])
        let prompt = try XCTUnwrap(context.data?.objectValue?["prompt"]?.stringValue)
        XCTAssertTrue(prompt.contains("biçimini koru"))
        XCTAssertTrue(prompt.contains("yalnızca incele"))
        XCTAssertEqual(context.data?.objectValue?["role"]?.stringValue, "reviewer")
    }

    func testBoardColumnsComeFromTheFilesHeadings() async throws {
        let board = await call("get_board")
        let columns = try XCTUnwrap(board.data?.objectValue?["columns"]?.arrayValue)
        XCTAssertEqual(
            columns.compactMap { $0.objectValue?["heading"]?.stringValue },
            ["Todo", "Done"]
        )
    }

    func testStatusFiltersAndUnknownStatusIsRejected() async throws {
        let unassigned = await call("list_unassigned_tasks")
        XCTAssertEqual(unassigned.data?.objectValue?["tasks"]?.arrayValue?.count, 4)

        let byStatus = await call("list_tasks_by_status", ["status": .string("done")])
        XCTAssertEqual(byStatus.data?.objectValue?["tasks"]?.arrayValue?.count, 1)

        let bogus = await call("list_tasks_by_status", ["status": .string("nonsense")])
        XCTAssertFalse(bogus.ok)
        XCTAssertEqual(bogus.error?.code, ControlErrorCode.invalidArgument.rawValue)

        let missing = await call("list_tasks_by_status")
        XCTAssertFalse(missing.ok)
    }

    // MARK: - Write

    func testCompletingATaskChangesOnlyItsCheckbox() async throws {
        let before = try read()
        let id = try await taskID("ilk görev")
        let envelope = await call("complete_task", ["task_id": .string(id)])

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data?.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(envelope.data?.objectValue?["diff"]?.stringValue?.contains("+[x]") ?? false)

        let after = try read()
        XCTAssertEqual(after, before.replacingOccurrences(of: "- [ ] ilk görev", with: "- [x] ilk görev"))
        XCTAssertTrue(after.contains("# Aşama 1"), "headings survive")
        XCTAssertTrue(after.contains("  açıklama satırı"), "indentation survives")
    }

    func testCompletingAnAlreadyDoneTaskChangesNothing() async throws {
        let id = try await taskID("bitmiş görev")
        let envelope = await call("complete_task", ["task_id": .string(id)])
        XCTAssertEqual(envelope.data?.objectValue?["changed"]?.boolValue, false)
    }

    func testReopenClearsTheCheckbox() async throws {
        let id = try await taskID("bitmiş görev")
        _ = await call("reopen_task", ["task_id": .string(id)])
        XCTAssertTrue(try read().contains("- [ ] bitmiş görev"))
    }

    func testUpdateRewritesOnlyTheTaskText() async throws {
        let id = try await taskID("ikinci görev")
        _ = await call("update_task", ["task_id": .string(id), "text": .string("yeni metin")])
        let after = try read()
        XCTAssertTrue(after.contains("- [ ] yeni metin"))
        XCTAssertTrue(after.contains("- [ ] ilk görev"), "the neighbour is untouched")
    }

    func testCreateTaskLandsUnderTheRequestedHeading() async throws {
        let envelope = await call("create_task", [
            "text": .string("yeni iş"), "heading": .string("Todo"),
        ])
        XCTAssertTrue(envelope.ok)
        let document = TodoParser.parse(try read(), path: "x")
        let created = document.tasks.first { $0.text == "yeni iş" }
        XCTAssertEqual(created?.headingPath, ["Aşama 1", "Todo"])
    }

    func testCreateSubtaskIsIndentedUnderItsParent() async throws {
        let parent = try await taskID("ikinci görev")
        let envelope = await call("create_subtask", [
            "parent_task_id": .string(parent), "text": .string("alt iş"),
        ])
        XCTAssertTrue(envelope.ok)
        let document = TodoParser.parse(try read(), path: "x")
        let child = document.tasks.first { $0.text == "alt iş" }
        XCTAssertEqual(child?.depth, 1)
        XCTAssertEqual(document.task(id: child?.parentID ?? "")?.text, "ikinci görev")
    }

    func testMoveTaskCarriesItsSubtasks() async throws {
        let id = try await taskID("ilk görev")
        let envelope = await call("move_task", [
            "task_id": .string(id), "heading": .string("Done"),
        ])
        XCTAssertTrue(envelope.ok)
        let document = TodoParser.parse(try read(), path: "x")
        XCTAssertEqual(document.tasks.first { $0.text == "ilk görev" }?.headingPath, ["Aşama 1", "Done"])
        XCTAssertEqual(document.tasks.first { $0.text == "alt görev" }?.headingPath, ["Aşama 1", "Done"])
    }

    func testAddNoteKeepsTheExistingDescription() async throws {
        let id = try await taskID("ilk görev")
        _ = await call("add_task_note", ["task_id": .string(id), "note": .string("yeni not")])
        let after = try read()
        XCTAssertTrue(after.contains("açıklama satırı"))
        XCTAssertTrue(after.contains("yeni not"))
    }

    func testAssignAndUnassignLeaveTheFileAlone() async throws {
        let before = try read()
        let id = try await taskID("ilk görev")

        let assigned = await call("assign_session", [
            "task_id": .string(id), "role": .string("reviewer"),
        ])
        XCTAssertTrue(assigned.ok)
        XCTAssertEqual(assigned.data?.objectValue?["role"]?.stringValue, "reviewer")

        let sessions = await call("list_task_sessions", ["task_id": .string(id)])
        XCTAssertEqual(sessions.data?.objectValue?["assignments"]?.arrayValue?.count, 1)

        let removed = await call("unassign_session", ["task_id": .string(id)])
        XCTAssertEqual(removed.data?.objectValue?["removed"]?.intValue, 1)
        XCTAssertEqual(try read(), before, "the file never changed")
    }

    func testExecutionStateNeedsAnAssignment() async throws {
        let id = try await taskID("ilk görev")
        let refused = await call("report_task_progress", ["task_id": .string(id)])
        XCTAssertFalse(refused.ok)

        _ = await call("assign_session", ["task_id": .string(id)])
        let reported = await call("report_task_progress", [
            "task_id": .string(id), "detail": .string("yarısı bitti"),
        ])
        XCTAssertTrue(reported.ok)
        XCTAssertEqual(reported.data?.objectValue?["execution_state"]?.stringValue, "running")

        let blocked = await call("set_task_blocked", [
            "task_id": .string(id), "reason": .string("API yok"),
        ])
        XCTAssertEqual(blocked.data?.objectValue?["execution_state"]?.stringValue, "blocked")

        let summary = await call(
            "summarize_task_results", ["task_id": .string(id)],
            capabilities: Array(PolicyEngine.defaultGrants) + ["tasks.orchestrate"]
        )
        let history = try XCTUnwrap(summary.data?.objectValue?["history"]?.arrayValue)
        XCTAssertTrue(history.contains { $0.objectValue?["detail"]?.stringValue == "API yok" })
    }

    // MARK: - Claims

    func testClaimIsExclusiveAndReleasable() async throws {
        let id = try await taskID("ilk görev")
        let first = await call("claim_task", ["task_id": .string(id)])
        XCTAssertTrue(first.ok)

        // A second session cannot take it while the claim is live.
        let project = store.projects[0]
        let other = store.createSession(
            projectID: project.id, provider: .codex, accountID: nil, title: "codex: y"
        )
        let blocked = await router.handle(ControlRequest(
            capability: "uncoil_tasks", action: "claim_task",
            args: ["task_id": .string(id)], caller_session_id: other.id.uuidString
        ))
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.error?.code, ControlErrorCode.permissionDenied.rawValue)

        _ = await call("release_task", ["task_id": .string(id)])
        let afterRelease = await router.handle(ControlRequest(
            capability: "uncoil_tasks", action: "claim_task",
            args: ["task_id": .string(id)], caller_session_id: other.id.uuidString
        ))
        XCTAssertTrue(afterRelease.ok)
    }

    // MARK: - Permission policy

    func testReadAndWriteAreDefaultButDestructiveAndOrchestrationAreNot() {
        XCTAssertTrue(PolicyEngine.defaultGrants.contains("tasks.read"))
        XCTAssertTrue(PolicyEngine.defaultGrants.contains("tasks.write"))
        for grant in ["tasks.delete", "tasks.orchestrate", "tasks.worktree", "tasks.merge"] {
            XCTAssertFalse(PolicyEngine.defaultGrants.contains(grant), grant)
            XCTAssertTrue(PolicyEngine.optionalGrants.contains(grant), grant)
        }
    }

    func testDeleteIsRefusedWithoutItsGrant() async throws {
        let id = try await taskID("ikinci görev")
        let refused = await call("delete_task", ["task_id": .string(id)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, ControlErrorCode.capabilityDisabled.rawValue)
        XCTAssertTrue(try read().contains("ikinci görev"), "nothing was removed")
    }

    func testDeleteRemovesTheWholeBlockWhenGranted() async throws {
        let id = try await taskID("ilk görev")
        let envelope = await call(
            "delete_task", ["task_id": .string(id)],
            capabilities: Array(PolicyEngine.defaultGrants) + ["tasks.delete"]
        )
        XCTAssertTrue(envelope.ok)
        let after = try read()
        XCTAssertFalse(after.contains("ilk görev"))
        XCTAssertFalse(after.contains("alt görev"), "children go with the parent")
        XCTAssertTrue(after.contains("ikinci görev"))
        XCTAssertTrue(after.contains("## Todo"), "the heading stays")
    }

    func testOrchestrationAndWorktreeAndMergeEachNeedTheirOwnGrant() async throws {
        let id = try await taskID("ilk görev")
        for action in ["spawn_task_agent", "wait_for_task_agents", "create_task_worktree", "submit_task_for_merge"] {
            let refused = await call(action, ["task_id": .string(id)])
            XCTAssertFalse(refused.ok, action)
            XCTAssertEqual(refused.error?.code, ControlErrorCode.capabilityDisabled.rawValue, action)
        }
    }

    func testMergeReportsReadinessRatherThanMerging() async throws {
        let id = try await taskID("ilk görev")
        _ = await call("assign_session", [
            "task_id": .string(id), "worktree_path": .string(projectRoot.path),
        ])
        let envelope = await call(
            "submit_task_for_merge", ["task_id": .string(id)],
            capabilities: Array(PolicyEngine.defaultGrants) + ["tasks.merge"]
        )
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(
            envelope.data?.objectValue?["merged"]?.boolValue, false,
            "Uncoil never merges on an agent's word"
        )
        XCTAssertFalse(envelope.next_actions.isEmpty)
    }

    // MARK: - Audit

    func testEveryPatchIsStoredWithItsDiff() async throws {
        let id = try await taskID("ilk görev")
        _ = await call("complete_task", ["task_id": .string(id)])

        let log = dataDir.appendingPathComponent("task-patches.jsonl")
        let contents = try XCTUnwrap(try? String(contentsOf: log, encoding: .utf8))
        XCTAssertTrue(contents.contains("\"diff\""))
        XCTAssertTrue(contents.contains("tamamlandı"))

        let diff = await call("get_task_diff", ["task_id": .string(id)])
        XCTAssertTrue(diff.ok)
        XCTAssertEqual(
            diff.data?.objectValue?["task_patches"]?.arrayValue?.count, 1,
            "the task's own patch history is reportable"
        )
    }

    func testHelpCoversEveryActionTheHandlerAccepts() async {
        let help = await call("help")
        XCTAssertTrue(help.ok)
        let documented = Set(HelpRegistry.actions(for: "uncoil_tasks"))
        for action in ["list_tasks", "complete_task", "delete_task", "claim_task",
                       "spawn_task_agent", "submit_task_for_merge"] {
            XCTAssertTrue(documented.contains(action), action)
        }
    }

    func testUnknownActionIsRejected() async {
        let envelope = await call("nonsense")
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.error?.code, ControlErrorCode.invalidAction.rawValue)
    }
}
