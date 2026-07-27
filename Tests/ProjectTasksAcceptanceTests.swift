import XCTest
@testable import Uncoil

/// Aşama 35 — the acceptance criteria for Project Tasks, one test per line of
/// the list. These exist so "done" means something checked, not something
/// assumed; each test names the criterion it stands for.
@MainActor
final class ProjectTasksAcceptanceTests: XCTestCase {
    private var dataDir: URL!
    private var projectRoot: URL!
    private var store: ProjectStore!
    private var sessionStore: SessionStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!

    /// A file that carries everything the parser has to survive: unusual
    /// spacing, mixed list markers, nesting, a fenced code block and an HTML
    /// comment.
    private let realisticFile = """
    # Uncoil TODO

    Serbest paragraf.

    ## Aşama 1 — hazırlık

    - [ ] ilk görev
      açıklama satırı
      - [x] alt görev bitti
      * [ ] farklı işaretli alt görev
    - [x]   fazladan boşluklu bitmiş görev\u{20}\u{20}

    ## Aşama 2 — kod

    * [ ] kod bloğu olan görev
      ```swift
      let x = 1  // - [ ] bu bir görev değil
      ```
      son satır
    + [ ] comment içeren görev
      <!-- uncoil: bu bir not, görev değil -->

    Son paragraf.
    """

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-accept-\(UUID().uuidString)", isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-accept-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projectRoot = root.resolvingSymlinksInPath()
        try write(realisticFile)

        store = ProjectStore(directory: dataDir)
        sessionStore = SessionStore()
        store.addProject(at: projectRoot)
        caller = store.createSession(
            projectID: store.projects[0].id, provider: .claude, accountID: nil,
            title: "claude: acceptance"
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

    // MARK: - Helpers

    private var todoURL: URL { projectRoot.appendingPathComponent("TODO.md") }

    private func write(_ contents: String) throws {
        try Data(contents.utf8).write(to: todoURL, options: .atomic)
    }

    private func read() throws -> String {
        try String(contentsOf: todoURL, encoding: .utf8)
    }

    private func document() throws -> TaskDocument {
        TodoParser.parse(try read(), path: todoURL.path)
    }

    private func task(_ text: String) throws -> ProjectTask {
        try XCTUnwrap(try document().tasks.first { $0.text == text })
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

    private func mcpTaskID(_ text: String) async throws -> String {
        let envelope = await call("list_tasks", ["limit": .int(200)])
        let tasks = try XCTUnwrap(envelope.data?.objectValue?["tasks"]?.arrayValue)
        return try XCTUnwrap(
            tasks.first { $0.objectValue?["text"]?.stringValue == text }?
                .objectValue?["task_id"]?.stringValue
        )
    }

    // MARK: - Display and formatting

    func testAnExistingTodoFileIsShownCorrectly() throws {
        let document = try document()
        XCTAssertEqual(
            document.tasks.map(\.text),
            [
                "ilk görev", "alt görev bitti", "farklı işaretli alt görev",
                "fazladan boşluklu bitmiş görev", "kod bloğu olan görev",
                "comment içeren görev",
            ]
        )
        XCTAssertEqual(document.headings.map(\.text).prefix(3).map { $0 }, [
            "Uncoil TODO", "Aşama 1 — hazırlık", "Aşama 2 — kod",
        ])
        XCTAssertEqual(document.openTasks.count, 4)
    }

    func testUnusualWhitespaceIndentationMarkersAndLineEndingsSurvive() throws {
        // One assertion covers criteria 2–5: a byte-identical round-trip means
        // nothing about the file's shape was normalised away.
        XCTAssertEqual(try document().render(), realisticFile)

        let crlf = "# T\r\n\r\n  - [ ] görev\r\n    açıklama\r\n"
        XCTAssertEqual(TodoParser.parse(crlf, path: "/p/TODO.md").render(), crlf)
        let parsed = TodoParser.parse(crlf, path: "/p/TODO.md")
        XCTAssertEqual(parsed.tasks[0].checkbox.indent, "  ")
        XCTAssertEqual(parsed.tasks[0].checkbox.listMarker, "-")
        XCTAssertEqual(
            try document().tasks.first { $0.text == "farklı işaretli alt görev" }?
                .checkbox.listMarker,
            "*",
            "the author's own list marker is kept"
        )
    }

    func testTogglingChangesOnlyTheCheckboxRange() throws {
        let before = try read()
        let target = try task("ilk görev")
        let patch = TodoEditor.togglePatch(for: target)
        XCTAssertEqual(patch.range.byteCount, 3)
        let after = try TodoEditor.apply([patch], to: before)
        XCTAssertEqual(after.utf8.count, before.utf8.count)
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .checkbox,
                allowedLines: TaskDiffAudit.allowedLines(for: target)
            ).isEmpty
        )
    }

    func testNestedTasksAndDescriptionsMoveWithTheCard() throws {
        let document = try document()
        let target = try XCTUnwrap(document.tasks.first { $0.text == "ilk görev" })
        let moved = try TodoEditor.apply(
            try TodoEditor.movePatches(task: target, to: ["Aşama 2 — kod"], in: document),
            to: try read()
        )
        let reparsed = TodoParser.parse(moved, path: todoURL.path)
        for text in ["ilk görev", "alt görev bitti", "farklı işaretli alt görev"] {
            XCTAssertEqual(
                reparsed.tasks.first { $0.text == text }?.headingPath.last,
                "Aşama 2 — kod",
                text
            )
        }
        XCTAssertTrue(moved.contains("  açıklama satırı"), "the description travels too")
        XCTAssertEqual(reparsed.tasks.count, document.tasks.count)
    }

    func testATaskWithACodeBlockIsNotBroken() throws {
        let target = try task("kod bloğu olan görev")
        XCTAssertTrue(target.rawBlock.contains("```swift"))
        XCTAssertFalse(
            try document().tasks.contains { $0.text.contains("bu bir görev değil") },
            "a checkbox inside a fenced block is code, not a task"
        )
        let after = try TodoEditor.apply([TodoEditor.togglePatch(for: target)], to: try read())
        XCTAssertTrue(after.contains("let x = 1  // - [ ] bu bir görev değil"))
        XCTAssertTrue(after.contains("* [x] kod bloğu olan görev"))
    }

    func testATaskWithAnHTMLCommentIsNotBroken() throws {
        let target = try task("comment içeren görev")
        XCTAssertTrue(target.rawBlock.contains("<!-- uncoil:"))
        let renamed = try XCTUnwrap(TodoEditor.renamePatch(for: target, to: "yeni ad"))
        let after = try TodoEditor.apply([renamed], to: try read())
        XCTAssertTrue(after.contains("<!-- uncoil: bu bir not, görev değil -->"))
        XCTAssertTrue(after.contains("+ [ ] yeni ad"))
    }

    // MARK: - Concurrency with agents

    func testAnExternalEditIsPickedUp() throws {
        let sources = TodoSourceStore(
            projectID: store.projects[0].id, projectRoot: projectRoot.path
        )
        sources.refresh()
        XCTAssertEqual(sources.allTasks.count, 6)

        try write(realisticFile + "\n- [ ] agent'ın eklediği görev\n")
        sources.refresh()
        XCTAssertTrue(
            sources.allTasks.contains { $0.text == "agent'ın eklediği görev" },
            "an edit made outside the app shows up on the next refresh"
        )
        let path = try XCTUnwrap(sources.sources.first?.path)
        XCTAssertEqual(
            sources.lastChanges[path]?.needsBoardRecompute, true,
            "\(sources.lastChanges)"
        )
    }

    func testASimultaneousEditLosesNothing() throws {
        let document = try document()
        let target = try XCTUnwrap(document.tasks.first { $0.text == "ilk görev" })

        // The agent adds a task while the UI is holding an older parse.
        try write(realisticFile + "\n- [ ] agent'ın eklediği görev\n")

        let outcome = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: target)],
            to: todoURL.path,
            expectedHash: document.contentHash,
            rebuild: TodoEditor.rebuilder(for: target) { [TodoEditor.togglePatch(for: $0)] }
        )
        guard case .recomputed = outcome else {
            return XCTFail("a stale write is recomputed, not clobbered: \(outcome)")
        }
        let after = try read()
        XCTAssertTrue(after.contains("- [x] ilk görev"), "the UI's edit landed")
        XCTAssertTrue(after.contains("agent'ın eklediği görev"), "the agent's edit survived")
    }

    func testAConflictIsNeverOverwritten() throws {
        let document = try document()
        let target = try XCTUnwrap(document.tasks.first { $0.text == "ilk görev" })
        // Someone rewrote the very block being edited.
        try write(realisticFile.replacingOccurrences(
            of: "- [ ] ilk görev", with: "- [ ] ilk görev, kullanıcı düzeltti"
        ))
        let before = try read()
        let outcome = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: target)],
            to: todoURL.path,
            expectedHash: document.contentHash,
            rebuild: TodoEditor.rebuilder(for: target) { _ in [] }
        )
        guard case .conflict = outcome else {
            return XCTFail("a change inside the edited block is a conflict: \(outcome)")
        }
        XCTAssertEqual(try read(), before, "the user's version is untouched")

        // And a file with markers in it is refused before a patch is even built.
        XCTAssertFalse(
            TaskFileGitStatus.from(
                porcelainCode: "UU", contents: "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n"
            ).isEditable
        )
    }

    func testAHalfWrittenPatchIsNeverLeftBehind() throws {
        let document = try document()
        let target = try XCTUnwrap(document.tasks.first { $0.text == "ilk görev" })
        try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: target)],
            to: todoURL.path,
            expectedHash: document.contentHash,
            backupDirectory: dataDir.appendingPathComponent("todo-backups", isDirectory: true)
        )
        // Atomic replacement: no temporary siblings survive the write.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: projectRoot.path)
        XCTAssertEqual(siblings.filter { $0.hasPrefix("TODO.md") }, ["TODO.md"])
        XCTAssertTrue(siblings.allSatisfy { !$0.hasSuffix(".tmp") }, "\(siblings)")
        XCTAssertNotNil(TodoParser.parse(try read(), path: todoURL.path).tasks.first)
    }

    // MARK: - No Uncoil syntax in the file

    func testTheFileNeedsNoUncoilSyntaxAndNeverGainsAny() async throws {
        let id = try await mcpTaskID("ilk görev")
        _ = await call("assign_session", ["task_id": .string(id)])
        _ = await call("report_task_progress", [
            "task_id": .string(id), "detail": .string("running"),
        ])
        _ = await call("add_task_note", [
            "task_id": .string(id), "note": .string("kullanıcı notu"),
        ])
        let contents = try read()
        XCTAssertFalse(contents.contains(caller.id.uuidString), "no session id in the file")
        XCTAssertFalse(
            contents.contains(store.projects[0].id.uuidString), "no project id in the file"
        )
        XCTAssertFalse(contents.contains("uncoil-task-id"))
        XCTAssertFalse(contents.contains(id), "not even Uncoil's own task id")
        XCTAssertTrue(contents.contains("kullanıcı notu"))
        // The parser needs nothing special either: a file with no Uncoil marks
        // at all is fully usable.
        XCTAssertEqual(TodoParser.parse("- [ ] sade görev\n", path: "/p/TODO.md").tasks.count, 1)
    }

    // MARK: - Task ↔ session relationships

    func testRelationshipsSurviveARestart() throws {
        let projectID = store.projects[0].id
        let target = try task("ilk görev")
        let first = ProjectTaskMetadataStore(projectID: projectID, dataDirectory: dataDir)
        first.assign(
            taskID: target.id, sourcePath: target.sourcePath, sessionID: caller.id,
            role: .implementer, fingerprint: target.fingerprint
        )

        let reopened = ProjectTaskMetadataStore(projectID: projectID, dataDirectory: dataDir)
        XCTAssertEqual(reopened.assignments(for: target.id).count, 1)
        XCTAssertEqual(reopened.assignments(for: target.id).first?.sessionID, caller.id)
    }

    func testASmallTextChangeKeepsTheRelationship() throws {
        let before = try task("ilk görev")
        try write(realisticFile.replacingOccurrences(
            of: "- [ ] ilk görev", with: "- [ ] ilk görev (küçük düzeltme)"
        ))
        let after = try document()
        let resolution = TaskRelinker.resolve(before.fingerprint, in: after.tasks)
        switch resolution {
        case .exact(let id), .positional(let id), .similar(let id, _):
            XCTAssertEqual(
                after.tasks.first { $0.id == id }?.text, "ilk görev (küçük düzeltme)"
            )
        case .ambiguous, .missing:
            XCTFail("a small edit keeps the link: \(resolution)")
        }
    }

    func testAnAmbiguousMatchIsNeverAttachedAutomatically() throws {
        let before = try task("ilk görev")
        // Two equally plausible candidates: nothing may be chosen for the user.
        let ambiguous = TodoParser.parse(
            """
            ## Aşama 1 — hazırlık

            - [ ] ilk görev A
            - [ ] ilk görev B
            """,
            path: todoURL.path
        )
        let resolution = TaskRelinker.resolve(before.fingerprint, in: ambiguous.tasks)
        switch resolution {
        case .ambiguous, .missing:
            break
        case .exact, .positional, .similar:
            XCTFail("an ambiguous match must be reported, not guessed: \(resolution)")
        }
    }

    // MARK: - Dispatch, claims and roles

    func testATaskIsHandedToAnAgentInOneStep() throws {
        let target = try task("ilk görev")
        let context = TaskPromptBuilder.context(
            for: target, in: try document(), project: store.projects[0],
            role: .implementer, worktreePath: nil, permissionProfile: []
        )
        let prompt = TaskPromptBuilder.prompt(context)
        XCTAssertTrue(prompt.contains("ilk görev"))
        XCTAssertTrue(prompt.contains("Preserve `TODO.md`'s formatting"), "the formatting rule always travels")
        XCTAssertFalse(TaskPromptBuilder.worktreeName(for: target).isEmpty)
    }

    func testAnAgentCanReportProgressOverMCP() async throws {
        let id = try await mcpTaskID("ilk görev")
        // Progress is reported against an assignment, which is how Uncoil knows
        // whose progress it is.
        let assigned = await call("assign_session", ["task_id": .string(id)])
        XCTAssertTrue(assigned.ok)
        let progress = await call("report_task_progress", [
            "task_id": .string(id), "detail": .string("yarısı bitti"),
        ])
        XCTAssertTrue(progress.ok)
        let sessions = await call("list_task_sessions", ["task_id": .string(id)])
        XCTAssertTrue(sessions.ok)
        let states = try XCTUnwrap(sessions.data?.objectValue?["assignments"]?.arrayValue)
        XCTAssertTrue(
            states.contains { $0.objectValue?["execution_state"]?.stringValue == "running" },
            "\(states)"
        )
    }

    func testTwoImplementersCannotClaimTheSameTask() async throws {
        let id = try await mcpTaskID("ilk görev")
        let claimed = await call("claim_task", ["task_id": .string(id)])
        XCTAssertTrue(claimed.ok)

        let other = store.createSession(
            projectID: store.projects[0].id, provider: .codex, accountID: nil,
            title: "codex: ikinci"
        )
        let refused = await router.handle(ControlRequest(
            capability: "uncoil_tasks", action: "claim_task",
            args: ["task_id": .string(id)],
            caller_session_id: other.id.uuidString
        ))
        XCTAssertFalse(refused.ok, "a live claim is exclusive")
    }

    func testReviewAndTestAgentsAttachWithTheirOwnRoles() throws {
        let target = try task("ilk görev")
        let metadata = ProjectTaskMetadataStore(
            projectID: store.projects[0].id, dataDirectory: dataDir
        )
        for role: TaskAgentRole in [.implementer, .reviewer, .tester] {
            metadata.assign(
                taskID: target.id, sourcePath: target.sourcePath, sessionID: UUID(),
                role: role, fingerprint: target.fingerprint
            )
        }
        XCTAssertEqual(
            Set(metadata.assignments(for: target.id).map(\.role)),
            [.implementer, .reviewer, .tester]
        )
    }

    func testAFailedAgentsClaimIsReleasedSafely() throws {
        let target = try task("ilk görev")
        let metadata = ProjectTaskMetadataStore(
            projectID: store.projects[0].id, dataDirectory: dataDir
        )
        let session = UUID()
        _ = metadata.claim(
            taskID: target.id, sourcePath: target.sourcePath, sessionID: session, duration: 60
        )
        XCTAssertNotNil(metadata.lease(for: target.id))

        // An expired lease frees the task without anyone having to say so.
        XCTAssertNil(
            metadata.lease(for: target.id, now: Date().addingTimeInterval(3_600)),
            "a dead agent's claim expires instead of blocking the task forever"
        )
        metadata.release(taskID: target.id, sessionID: session)
        XCTAssertNil(metadata.lease(for: target.id))
    }

    // MARK: - Tests, review and merge gates

    func testATestResultIsVerifiedBeforeCompletion() async throws {
        let id = try await mcpTaskID("ilk görev")
        _ = await call("report_test_result", [
            "task_id": .string(id), "command": .string("xcodebuild test"),
            "passed": .bool(false), "summary": .string("1 test kırık"),
        ])
        let refused = await call("complete_task", ["task_id": .string(id)])
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(try read().contains("- [ ] ilk görev"))

        _ = await call("report_test_result", [
            "task_id": .string(id), "command": .string("xcodebuild test"),
            "passed": .bool(true), "summary": .string("passed"),
        ])
        let allowed = await call("complete_task", ["task_id": .string(id)])
        XCTAssertTrue(allowed.ok)
    }

    func testAFailedReviewKeepsTheTaskOutOfDone() async throws {
        let id = try await mcpTaskID("ilk görev")
        _ = await call("submit_task_review", [
            "task_id": .string(id), "verdict": .string("changesRequested"),
            "findings": .array([.string("hata yolu yok")]),
        ])
        let refused = await call("complete_task", ["task_id": .string(id)])
        XCTAssertFalse(refused.ok, "a task whose review asked for changes is not done")
        XCTAssertTrue(try read().contains("- [ ] ilk görev"))

        let results = TaskResultStore(
            projectID: store.projects[0].id, dataDirectory: dataDir
        )
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [], reviews: results.reviews(for: id), conflictedFiles: [],
                uncommittedChanges: 0, userApproved: true, settings: .default
            ).contains(.changesRequested),
            "and it cannot be merged either"
        )
    }

    func testTheGitDiffContainsOnlyTheExpectedTodoLines() async throws {
        let before = try read()
        let id = try await mcpTaskID("comment içeren görev")
        let envelope = await call("complete_task", ["task_id": .string(id)])
        XCTAssertTrue(envelope.ok)
        let after = try read()
        let target = try XCTUnwrap(
            TodoParser.parse(before, path: todoURL.path).tasks
                .first { $0.text == "comment içeren görev" }
        )
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .checkbox,
                allowedLines: TaskDiffAudit.allowedLines(for: target)
            ).isEmpty,
            "nothing outside the task's own block changed"
        )
        let diff = try XCTUnwrap(envelope.data?.objectValue?["diff"]?.stringValue)
        XCTAssertTrue(diff.contains("+[x]"))
        XCTAssertFalse(diff.contains("Son paragraf"))
    }

    // MARK: - Orchestrator restart

    func testTheOrchestratorRestoresItsPlanAfterARestart() throws {
        let projectID = store.projects[0].id
        let document = try document()
        let plan = TaskOrchestrator.plan(TaskOrchestrator.Input(
            projectID: projectID,
            tasks: document.openTasks,
            assignments: [:],
            claimStates: [:],
            settings: .default,
            now: Date(timeIntervalSince1970: 0)
        ))
        let first = OrchestratorStore(projectID: projectID, dataDirectory: dataDir)
        first.store(plan)
        let pending = first.pending.count
        XCTAssertGreaterThan(pending, 0)

        let restarted = OrchestratorStore(projectID: projectID, dataDirectory: dataDir)
        XCTAssertEqual(restarted.pending.count, pending, "the active plan comes back")
        XCTAssertEqual(
            restarted.pending.map(\.taskID).sorted(),
            first.pending.map(\.taskID).sorted()
        )

        // And stopping it drops exactly the work that had not started.
        XCTAssertEqual(restarted.stopDispatching(), pending)
        XCTAssertTrue(
            OrchestratorStore(projectID: projectID, dataDirectory: dataDir).pending.isEmpty
        )
    }
}
