import Foundation

/// `uncoil_tasks`: lets an agent read and edit the project's own `TODO.md`
/// through Uncoil rather than by rewriting the file itself.
///
/// Every write goes through the same byte-range patch path the UI uses, so an
/// agent cannot reformat the user's file, and each patch is audited with its
/// diff. Reading and editing are the default grants; deleting a task, spawning
/// agents, cutting a worktree and asking for a merge each need their own.
extension CapabilityRouter {
    // MARK: - Entry point

    func handleTasks(_ request: ControlRequest) async -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let grants = PolicyEngine.grants(for: caller)

        switch request.action {
        // 28.1 — read
        case "list_todo_files":
            return requiring("tasks.read", grants, request) { listTodoFiles(request, caller: caller) }
        case "list_tasks":
            return requiring("tasks.read", grants, request) { listTasks(request, caller: caller) }
        case "get_task":
            return requiring("tasks.read", grants, request) { getTask(request, caller: caller) }
        case "get_task_context":
            return requiring("tasks.read", grants, request) { getTaskContext(request, caller: caller) }
        case "get_board":
            return requiring("tasks.read", grants, request) { getBoard(request, caller: caller) }
        case "list_task_sessions":
            return requiring("tasks.read", grants, request) { listTaskSessions(request, caller: caller) }
        case "list_unassigned_tasks":
            return requiring("tasks.read", grants, request) {
                listFiltered(request, caller: caller, status: .unassigned)
            }
        case "list_blocked_tasks":
            return requiring("tasks.read", grants, request) {
                listFiltered(request, caller: caller, status: .blocked)
            }
        case "list_tasks_by_status":
            return requiring("tasks.read", grants, request) { listByStatus(request, caller: caller) }
        case "get_task_diff":
            return requiring("tasks.read", grants, request) { getTaskDiff(request, caller: caller) }

        // 28.2 — write
        case "create_task":
            return requiring("tasks.write", grants, request) {
                createTask(request, caller: caller, asSubtask: false)
            }
        case "create_subtask":
            return requiring("tasks.write", grants, request) {
                createTask(request, caller: caller, asSubtask: true)
            }
        case "update_task":
            return requiring("tasks.write", grants, request) { updateTask(request, caller: caller) }
        case "complete_task":
            return requiring("tasks.write", grants, request) {
                setChecked(request, caller: caller, done: true)
            }
        case "reopen_task":
            return requiring("tasks.write", grants, request) {
                setChecked(request, caller: caller, done: false)
            }
        case "move_task":
            return requiring("tasks.write", grants, request) { moveTask(request, caller: caller) }
        case "add_task_note":
            return requiring("tasks.write", grants, request) { addNote(request, caller: caller) }
        case "assign_session":
            return requiring("tasks.write", grants, request) { assignSession(request, caller: caller) }
        case "unassign_session":
            return requiring("tasks.write", grants, request) { unassignSession(request, caller: caller) }
        case "set_task_blocked", "mark_task_blocked":
            return requiring("tasks.write", grants, request) {
                setExecutionState(request, caller: caller, state: .blocked)
            }
        case "request_task_review":
            return requiring("tasks.write", grants, request) {
                setExecutionState(request, caller: caller, state: .reviewRequested)
            }
        case "report_task_progress":
            return requiring("tasks.write", grants, request) {
                setExecutionState(request, caller: caller, state: .running)
            }
        case "complete_task_execution":
            return requiring("tasks.write", grants, request) {
                setExecutionState(request, caller: caller, state: .completed)
            }

        // 28.2 — destructive
        case "delete_task":
            return requiring("tasks.delete", grants, request) { deleteTask(request, caller: caller) }

        // 28.3 — orchestration
        case "claim_task":
            return requiring("tasks.write", grants, request) { claimTask(request, caller: caller) }
        case "release_task":
            return requiring("tasks.write", grants, request) { releaseTask(request, caller: caller) }
        case "dispatch_task", "spawn_task_agent":
            guard grants.contains("tasks.orchestrate") else {
                return .failure(
                    request, code: .capabilityDisabled,
                    message: "tasks.orchestrate is not granted"
                )
            }
            return await spawnTaskAgent(request, caller: caller)
        case "wait_for_task_agents":
            return requiring("tasks.orchestrate", grants, request) {
                waitForTaskAgents(request, caller: caller)
            }
        case "summarize_task_results":
            return requiring("tasks.orchestrate", grants, request) {
                summarizeTaskResults(request, caller: caller)
            }
        case "create_task_worktree":
            return requiring("tasks.worktree", grants, request) {
                createTaskWorktree(request, caller: caller)
            }
        case "report_test_result":
            return requiring("tasks.write", grants, request) {
                reportTestResult(request, caller: caller)
            }
        case "submit_task_review":
            return requiring("tasks.write", grants, request) {
                submitTaskReview(request, caller: caller)
            }
        case "get_task_results":
            return requiring("tasks.read", grants, request) {
                getTaskResults(request, caller: caller)
            }
        case "submit_task_for_merge":
            return requiring("tasks.merge", grants, request) {
                submitForMerge(request, caller: caller)
            }

        default:
            return .failure(request, code: .invalidAction, message: "unsupported task action")
        }
    }

    private func requiring(
        _ grant: String,
        _ grants: Set<String>,
        _ request: ControlRequest,
        _ body: () -> ControlEnvelope
    ) -> ControlEnvelope {
        guard grants.contains(grant) else {
            return .failure(
                request, code: .capabilityDisabled,
                message: "\(grant) is not granted"
            )
        }
        return body()
    }

    // MARK: - Resolution

    /// The project a task request is about: the caller's, or an explicit one when
    /// the caller may reach across projects.
    private func taskProject(_ request: ControlRequest, caller: SessionRecord) -> Project? {
        let grants = PolicyEngine.grants(for: caller)
        if let raw = request.args["project_id"]?.stringValue,
           let id = UUID(uuidString: raw),
           id != caller.projectID {
            guard grants.contains("sessions.cross_project") else { return nil }
            return projectStore.projects.first { $0.id == id }
        }
        return projectStore.projects.first { $0.id == caller.projectID }
    }

    private func loadDocuments(
        _ project: Project
    ) -> [(source: ProjectTaskSource, document: TaskDocument)] {
        TodoDiscovery.load(projectID: project.id, projectRoot: project.rootPath)
    }

    /// Finds a task by id across the project's sources.
    private func findTask(
        _ taskID: String,
        in loaded: [(source: ProjectTaskSource, document: TaskDocument)]
    ) -> (task: ProjectTask, document: TaskDocument)? {
        for entry in loaded {
            if let task = entry.document.task(id: taskID) {
                return (task, entry.document)
            }
        }
        return nil
    }

    private func metadata(for project: Project) -> ProjectTaskMetadataStore {
        if let existing = taskMetadataStores[project.id] { return existing }
        let store = ProjectTaskMetadataStore(projectID: project.id, dataDirectory: dataDirectory)
        taskMetadataStores[project.id] = store
        return store
    }

    private func results(for project: Project) -> TaskResultStore {
        if let existing = taskResultStores[project.id] { return existing }
        let store = TaskResultStore(projectID: project.id, dataDirectory: dataDirectory)
        taskResultStores[project.id] = store
        return store
    }

    private func orchestratorSettings(for project: Project) -> OrchestratorSettings {
        OrchestratorStore(projectID: project.id, dataDirectory: dataDirectory).settings
    }

    private func taskJSON(
        _ task: ProjectTask,
        state: ProjectTaskExecutionState,
        includeBlock: Bool = false
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "task_id": .string(task.id),
            "text": .string(task.text),
            "done": .bool(task.isDone),
            "source_path": .string(task.sourcePath),
            "heading_path": .array(task.headingPath.map(JSONValue.string)),
            "depth": .int(task.depth),
            "line": .int(task.lineRange.startLine),
            "execution_state": .string(state.rawValue),
            "subtask_ids": .array(task.childIDs.map(JSONValue.string)),
        ]
        if includeBlock {
            object["raw_block"] = .string(task.rawBlock)
        }
        return .object(object)
    }

    // MARK: - 28.1 Read

    private func listTodoFiles(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        let files = loadDocuments(project).map { entry in
            JSONValue.object([
                "path": .string(entry.source.path),
                "display_path": .string(entry.source.displayPath),
                "task_count": .int(entry.source.taskCount),
                "open_task_count": .int(entry.source.openTaskCount),
                "content_hash": .string(entry.source.contentHash),
            ])
        }
        return .success(
            request, data: .object(["todo_files": .array(files)]),
            project_id: project.id.uuidString
        )
    }

    private func listTasks(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        let store = metadata(for: project)
        var tasks = TodoDiscovery.aggregate(loadDocuments(project))
        if let path = request.args["source_path"]?.stringValue {
            tasks = tasks.filter { $0.sourcePath == path }
        }
        if let heading = request.args["heading"]?.stringValue {
            tasks = tasks.filter { $0.headingPath.contains(heading) }
        }
        if request.args["open_only"]?.boolValue == true {
            tasks = tasks.filter { !$0.isDone }
        }
        let limit = min(request.args["limit"]?.intValue ?? 200, 500)
        let payload = tasks.prefix(limit).map {
            taskJSON($0, state: store.executionState(for: $0.id))
        }
        return .success(
            request,
            data: .object([
                "tasks": .array(payload),
                "total": .int(tasks.count),
                "truncated": .bool(tasks.count > limit),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func getTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        guard let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let store = metadata(for: project)
        return .success(
            request,
            data: taskJSON(
                found.task, state: store.executionState(for: found.task.id), includeBlock: true
            ),
            project_id: project.id.uuidString
        )
    }

    private func getTaskContext(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let store = metadata(for: project)
        let role = request.args["role"]?.stringValue
            .flatMap(TaskAgentRole.init(rawValue:)) ?? .implementer
        let worktree = store.assignments(for: found.task.id).compactMap(\.worktreePath).first
        let context = TaskPromptBuilder.context(
            for: found.task, in: found.document, project: project, role: role,
            worktreePath: worktree, permissionProfile: Array(PolicyEngine.grants(for: caller)).sorted(),
            language: agentPromptLanguage
        )
        return .success(
            request,
            data: .object([
                "prompt": .string(TaskPromptBuilder.prompt(context)),
                "project_path": .string(project.rootPath),
                "source_path": .string(found.task.sourcePath),
                "heading_path": .array(found.task.headingPath.map(JSONValue.string)),
                "raw_block": .string(found.task.rawBlock),
                "subtasks": .array(context.subtaskBlocks.map(JSONValue.string)),
                "role": .string(role.rawValue),
                "worktree_path": .string(optional: worktree),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func getBoard(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        let loaded = loadDocuments(project)
        let store = metadata(for: project)
        guard let entry = request.args["source_path"]?.stringValue
            .flatMap({ path in loaded.first { $0.source.path == path } }) ?? loaded.first else {
            return .success(request, data: .object(["columns": .array([])]),
                            project_id: project.id.uuidString)
        }
        let columns = TaskBoardMapping.columns(
            for: entry.document, overrides: store.preferences.headingOverrides,
            columnOrder: store.preferences.columnOrder
        )
        let payload = columns.map { column in
            JSONValue.object([
                "heading": .string(column.heading),
                "title": .string(column.title),
                "lane": .string(column.lane.rawValue),
                "is_custom": .bool(column.isCustom),
                "tasks": .array(
                    TaskBoardMapping.tasks(in: column, of: entry.document).map {
                        taskJSON($0, state: store.executionState(for: $0.id))
                    }
                ),
            ])
        }
        return .success(
            request,
            data: .object([
                "source_path": .string(entry.source.path),
                "columns": .array(payload),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func listTaskSessions(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        let store = metadata(for: project)
        let assignments = request.args["task_id"]?.stringValue
            .map { store.assignments(for: $0) } ?? store.document.assignments
        let payload = assignments.map { assignment in
            JSONValue.object([
                "assignment_id": .string(assignment.id.uuidString),
                "task_id": .string(assignment.taskID),
                "session_id": .string(assignment.sessionID.uuidString),
                "role": .string(assignment.role.rawValue),
                "execution_state": .string(assignment.state.rawValue),
                "worktree_path": .string(optional: assignment.worktreePath),
                "needs_relinking": .bool(assignment.needsRelinking),
            ])
        }
        return .success(
            request, data: .object(["assignments": .array(payload)]),
            project_id: project.id.uuidString
        )
    }

    private func listFiltered(
        _ request: ControlRequest,
        caller: SessionRecord,
        status: TaskFilter.Status
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        let store = metadata(for: project)
        var filter = TaskFilter()
        filter.status = status
        let tasks = filter.apply(
            to: TodoDiscovery.aggregate(loadDocuments(project)),
            assignments: store.assignmentsByTask
        )
        return .success(
            request,
            data: .object([
                "status": .string(status.rawValue),
                "tasks": .array(tasks.map { taskJSON($0, state: store.executionState(for: $0.id)) }),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func listByStatus(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let raw = request.args["status"]?.stringValue else {
            return .failure(
                request, code: .invalidArgument,
                message: "'status' is required (\(TaskFilter.Status.allCases.map(\.rawValue).joined(separator: ", ")))"
            )
        }
        guard let status = TaskFilter.Status(rawValue: raw) else {
            return .failure(request, code: .invalidArgument, message: "unknown status '\(raw)'")
        }
        return listFiltered(request, caller: caller, status: status)
    }

    private func getTaskDiff(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = metadata(for: project)
        let worktree = store.assignments(for: taskID).compactMap(\.worktreePath).first
        let path = worktree ?? project.rootPath
        let snapshot = GitService.snapshot(repoPath: path)
        return .success(
            request,
            data: .object([
                "repo_path": .string(path),
                "branch": .string(optional: snapshot.branch),
                "changed_files": .array(snapshot.changedFiles.map {
                    .object(["status": .string($0.status), "path": .string($0.path)])
                }),
                // The patches Uncoil itself wrote for this task, newest first.
                "task_patches": .array(taskPatchLog(taskID: taskID).map(JSONValue.string)),
            ]),
            project_id: project.id.uuidString
        )
    }

    // MARK: - 28.2 Write

    /// One place every task write funnels through: patch, audit with the diff,
    /// and report what happened.
    private func applyPatches(
        _ patches: [TodoEditor.Patch],
        task: ProjectTask?,
        document: TaskDocument,
        request: ControlRequest,
        caller: SessionRecord,
        project: Project,
        summary: String,
        extra: [String: JSONValue] = [:]
    ) -> ControlEnvelope {
        guard !patches.isEmpty else {
            return .success(request, data: .object(["changed": .bool(false)]),
                            project_id: project.id.uuidString)
        }
        let diff = TodoEditor.diff(patches, in: document.raw)
        do {
            let outcome = try TodoEditor.write(
                patches: patches,
                to: document.path,
                expectedHash: document.contentHash,
                rebuild: task.map { target in
                    // An unrelated change elsewhere is fine; a change in this
                    // task's own block is a conflict the agent must re-read.
                    TodoEditor.rebuilder(for: target) { _ in [] }
                },
                backupDirectory: dataDirectory
                    .appendingPathComponent("todo-backups", isDirectory: true)
            )
            switch outcome {
            case .written(let hash), .recomputed(let hash):
                recordTaskPatch(taskID: task?.id, path: document.path, diff: diff, summary: summary)
                audit.record(
                    requestID: request.request_id,
                    callerSessionID: request.caller_session_id,
                    capability: request.capability,
                    action: request.action,
                    target: task?.id,
                    decision: "allow",
                    argKeys: Array(request.args.keys)
                )
                var data: [String: JSONValue] = [
                    "changed": .bool(true),
                    "content_hash": .string(hash),
                    "diff": .string(diff),
                ]
                extra.forEach { data[$0.key] = $0.value }
                return .success(request, data: .object(data), project_id: project.id.uuidString)
            case .conflict(let detail):
                return .failure(
                    request, code: .invalidArgument,
                    message: "\(detail) Re-read the task and try again.",
                    retryable: true
                )
            }
        } catch {
            return .failure(
                request, code: .invalidArgument,
                message: error.localizedDescription, retryable: true
            )
        }
    }

    private func setChecked(
        _ request: ControlRequest,
        caller: SessionRecord,
        done: Bool
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        guard found.task.isDone != done else {
            return .success(
                request,
                data: .object(["changed": .bool(false), "done": .bool(done)]),
                project_id: project.id.uuidString
            )
        }
        // A failing test run refuses the tick. The gate is enforced here, in the
        // write path, rather than only being available to callers who ask.
        if done {
            let blockers = results(for: project).failingTestBlockers(taskID: taskID)
            if !blockers.isEmpty {
                return .failure(
                    request, code: .invalidArgument,
                    message: "the task cannot be completed: "
                        + blockers.map(\.message).joined(separator: " ")
                        + " Fix it and report the test result again.",
                    retryable: true
                )
            }
        }
        let store = metadata(for: project)
        store.setState(done ? .completed : .queued, taskID: taskID)
        return applyPatches(
            [TodoEditor.togglePatch(for: found.task)],
            task: found.task, document: found.document, request: request,
            caller: caller, project: project,
            summary: done ? "done" : "reopened",
            extra: ["done": .bool(done)]
        )
    }

    private func updateTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        var patches: [TodoEditor.Patch] = []
        if let text = request.args["text"]?.stringValue,
           let patch = TodoEditor.renamePatch(for: found.task, to: text) {
            patches.append(patch)
        }
        if let body = request.args["description"]?.stringValue,
           let patch = TodoEditor.descriptionPatch(for: found.task, to: body) {
            patches.append(patch)
        }
        return applyPatches(
            patches, task: found.task, document: found.document, request: request,
            caller: caller, project: project, summary: "updated"
        )
    }

    private func addNote(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let note = request.args["note"]?.stringValue, !note.isEmpty,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "'task_id' and 'note' are required")
        }
        // A note is appended to the task's own description, keeping whatever is
        // already there.
        let existing = found.task.rawBlock
            .components(separatedBy: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let body = (existing + [note]).joined(separator: "\n")
        guard let patch = TodoEditor.descriptionPatch(for: found.task, to: body) else {
            return .failure(request, code: .invalidArgument, message: "note could not be applied")
        }
        return applyPatches(
            [patch], task: found.task, document: found.document, request: request,
            caller: caller, project: project, summary: "note added"
        )
    }

    private func moveTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let heading = request.args["heading"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(
                request, code: .invalidArgument,
                message: "'task_id' and 'heading' are required"
            )
        }
        do {
            let patches = try TodoEditor.movePatches(
                task: found.task, to: [heading], in: found.document
            )
            return applyPatches(
                patches, task: found.task, document: found.document, request: request,
                caller: caller, project: project, summary: "moved: \(heading)"
            )
        } catch {
            return .failure(request, code: .invalidArgument, message: error.localizedDescription)
        }
    }

    private func createTask(
        _ request: ControlRequest,
        caller: SessionRecord,
        asSubtask: Bool
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let text = request.args["text"]?.stringValue, !text.isEmpty else {
            return .failure(request, code: .invalidArgument, message: "'text' is required")
        }
        let loaded = loadDocuments(project)

        if asSubtask {
            guard let parentID = request.args["parent_task_id"]?.stringValue,
                  let found = findTask(parentID, in: loaded) else {
                return .failure(
                    request, code: .invalidArgument,
                    message: "'parent_task_id' is required and must exist"
                )
            }
            // A subtask is a line indented under its parent, inserted at the end
            // of the parent's own block.
            let indent = found.task.checkbox.indent + "  "
            let line = TodoEditor.separator(
                before: found.task.blockRange.endByte, in: found.document.raw
            ) + "\(indent)\(found.task.checkbox.listMarker) [ ] \(text)\n"
            let patch = TodoEditor.Patch(
                range: TaskSourceRange(
                    startByte: found.task.blockRange.endByte,
                    endByte: found.task.blockRange.endByte,
                    startLine: found.task.blockRange.endLine,
                    endLine: found.task.blockRange.endLine,
                    startColumn: 1
                ),
                replacement: line,
                summary: "subtask added: \(text)"
            )
            return applyPatches(
                [patch], task: found.task, document: found.document, request: request,
                caller: caller, project: project, summary: "subtask added"
            )
        }

        guard let entry = request.args["source_path"]?.stringValue
            .flatMap({ path in loaded.first { $0.source.path == path } }) ?? loaded.first else {
            return .failure(
                request, code: .invalidArgument,
                message: "no TODO.md in this project to add a task to"
            )
        }
        let heading = request.args["heading"]?.stringValue
        let document = entry.document
        // Placed after the last task under the requested heading, or at the end.
        // The heading is matched on its own name, not the whole chain: a caller
        // naming "Todo" means the section called Todo, wherever it sits.
        let underHeading = heading.map { name in
            document.tasks.filter { $0.headingPath.last == name }
        }
        let anchor = underHeading?.last?.blockRange.endByte
            ?? document.tasks.last?.blockRange.endByte
            ?? document.raw.utf8.count
        var line = "- [ ] \(text)\n"
        if anchor == document.raw.utf8.count, !document.raw.hasSuffix("\n"), !document.raw.isEmpty {
            line = "\n" + line
        }
        let patch = TodoEditor.Patch(
            range: TaskSourceRange(
                startByte: anchor, endByte: anchor,
                startLine: 1, endLine: 1, startColumn: 1
            ),
            replacement: line,
            summary: "task added: \(text)"
        )
        return applyPatches(
            [patch], task: nil, document: document, request: request,
            caller: caller, project: project, summary: "task added"
        )
    }

    private func deleteTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        // The whole block goes, children included — the same span a move cuts.
        let block = TodoEditor.blockWithDescendants(of: found.task, in: found.document)
        let patch = TodoEditor.Patch(
            range: block.range, replacement: "",
            summary: "task deleted: \(found.task.text)"
        )
        return applyPatches(
            [patch], task: found.task, document: found.document, request: request,
            caller: caller, project: project, summary: "task deleted"
        )
    }

    private func assignSession(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let sessionID = request.args["session_id"]?.stringValue
            .flatMap(UUID.init(uuidString:)) ?? caller.id
        let role = request.args["role"]?.stringValue
            .flatMap(TaskAgentRole.init(rawValue:)) ?? .implementer
        let assignment = metadata(for: project).assign(
            taskID: found.task.id, sourcePath: found.task.sourcePath,
            sessionID: sessionID, role: role,
            worktreePath: request.args["worktree_path"]?.stringValue,
            fingerprint: found.task.fingerprint
        )
        return .success(
            request,
            data: .object([
                "assignment_id": .string(assignment.id.uuidString),
                "task_id": .string(found.task.id),
                "session_id": .string(sessionID.uuidString),
                "role": .string(role.rawValue),
            ]),
            project_id: project.id.uuidString,
            target_session_id: sessionID.uuidString
        )
    }

    private func unassignSession(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = metadata(for: project)
        let sessionID = request.args["session_id"]?.stringValue
            .flatMap(UUID.init(uuidString:)) ?? caller.id
        let removed = store.assignments(for: taskID).filter { $0.sessionID == sessionID }
        removed.forEach { store.removeAssignment(id: $0.id) }
        // Unlinking changes nothing about the task itself.
        return .success(
            request,
            data: .object([
                "removed": .int(removed.count),
                "task_id": .string(taskID),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func setExecutionState(
        _ request: ControlRequest,
        caller: SessionRecord,
        state: ProjectTaskExecutionState
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = metadata(for: project)
        let detail = request.args["detail"]?.stringValue ?? request.args["reason"]?.stringValue
        let mine = store.assignments(for: taskID).filter { $0.sessionID == caller.id }
        let targets = mine.isEmpty ? store.assignments(for: taskID) : mine
        guard !targets.isEmpty else {
            return .failure(
                request, code: .invalidArgument,
                message: "no session is assigned to this task; call assign_session first"
            )
        }
        targets.forEach { store.setState(state, assignmentID: $0.id, detail: detail) }
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "execution_state": .string(state.rawValue),
                "updated": .int(targets.count),
            ]),
            project_id: project.id.uuidString
        )
    }

    // MARK: - 28.3 Orchestration

    private func claimTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let duration = TimeInterval(request.args["duration_seconds"]?.intValue ?? 900)
        guard let lease = metadata(for: project).claim(
            taskID: found.task.id, sourcePath: found.task.sourcePath,
            sessionID: caller.id, duration: max(60, min(duration, 3600))
        ) else {
            return .failure(
                request, code: .permissionDenied,
                message: "task is already claimed by another session", retryable: true
            )
        }
        return .success(
            request,
            data: .object([
                "task_id": .string(found.task.id),
                "expires_at": .string(ISO8601DateFormatter().string(from: lease.expiresAt)),
                "generation": .int(lease.generation),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func releaseTask(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        metadata(for: project).release(taskID: taskID, sessionID: caller.id)
        return .success(
            request, data: .object(["released": .bool(true)]),
            project_id: project.id.uuidString
        )
    }

    private func spawnTaskAgent(
        _ request: ControlRequest,
        caller: SessionRecord
    ) async -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let role = request.args["role"]?.stringValue
            .flatMap(TaskAgentRole.init(rawValue:)) ?? .implementer
        // A child is created through the same preset path as create_child, so its
        // capabilities are the preset intersected with the caller's — never more.
        var childRequest = request
        childRequest.args = [
            "preset_id": request.args["preset_id"] ?? .string(
                role == .reviewer ? "codex-reviewer" : "claude-worker"
            ),
            "title": .string("\(role.label): \(found.task.text)"),
            "initial_prompt": .string(TaskPromptBuilder.prompt(TaskPromptBuilder.context(
                for: found.task, in: found.document, project: project, role: role,
                worktreePath: request.args["worktree_path"]?.stringValue,
                permissionProfile: [],
                language: agentPromptLanguage
            ))),
        ]
        if let worktree = request.args["worktree_path"] {
            childRequest.args["worktree_path"] = worktree
        }
        let envelope = await handleSessions(childRequest.replacingAction("create_child"))
        guard envelope.ok,
              let childID = envelope.data?.objectValue?["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: childID) else {
            return envelope
        }
        let assignment = metadata(for: project).assign(
            taskID: found.task.id, sourcePath: found.task.sourcePath,
            sessionID: sessionID, role: role,
            worktreePath: request.args["worktree_path"]?.stringValue,
            fingerprint: found.task.fingerprint
        )
        metadata(for: project).setState(.agentStarting, assignmentID: assignment.id)
        return .success(
            request,
            data: .object([
                "task_id": .string(found.task.id),
                "session_id": .string(childID),
                "assignment_id": .string(assignment.id.uuidString),
                "role": .string(role.rawValue),
            ]),
            project_id: project.id.uuidString,
            target_session_id: childID
        )
    }

    private func waitForTaskAgents(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        // Non-blocking by design: a blocking wait would hold the control socket.
        // The caller polls, and gets told what it is still waiting on.
        let assignments = metadata(for: project).assignments(for: taskID)
        let pending = assignments.filter { $0.state.isActive || $0.state == .queued }
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "settled": .bool(pending.isEmpty),
                "pending": .array(pending.map {
                    .object([
                        "session_id": .string($0.sessionID.uuidString),
                        "role": .string($0.role.rawValue),
                        "execution_state": .string($0.state.rawValue),
                    ])
                }),
            ]),
            project_id: project.id.uuidString,
            next_actions: pending.isEmpty ? [] : ["wait_for_task_agents"]
        )
    }

    private func summarizeTaskResults(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = metadata(for: project)
        let formatter = ISO8601DateFormatter()
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "execution_state": .string(store.executionState(for: taskID).rawValue),
                "assignments": .array(store.assignments(for: taskID).map { assignment in
                    .object([
                        "session_id": .string(assignment.sessionID.uuidString),
                        "role": .string(assignment.role.rawValue),
                        "execution_state": .string(assignment.state.rawValue),
                    ])
                }),
                "history": .array(store.history(for: taskID).prefix(50).map { event in
                    .object([
                        "state": .string(event.state.rawValue),
                        "at": .string(formatter.string(from: event.at)),
                        "detail": .string(optional: event.detail),
                    ])
                }),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func createTaskWorktree(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        let name = request.args["name"]?.stringValue
            ?? TaskPromptBuilder.worktreeName(for: found.task)
        switch GitService.createWorktree(repoPath: project.rootPath, name: name) {
        case .success(let worktree):
            return .success(
                request,
                data: .object([
                    "task_id": .string(found.task.id),
                    "path": .string(worktree.path),
                    "branch": .string(optional: worktree.branch),
                ]),
                project_id: project.id.uuidString
            )
        case .failure(let error):
            return .failure(request, code: .invalidArgument, message: error.message)
        }
    }

    // MARK: - Tests, reviews and merge readiness

    private func reportTestResult(
        _ request: ControlRequest,
        caller: SessionRecord
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              findTask(taskID, in: loadDocuments(project)) != nil else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        guard let command = request.args["command"]?.stringValue, !command.isEmpty else {
            return .failure(request, code: .invalidArgument, message: "'command' is required")
        }
        guard let passed = request.args["passed"]?.boolValue else {
            return .failure(request, code: .invalidArgument, message: "'passed' (bool) is required")
        }
        let result = TaskTestResult(
            taskID: taskID,
            sessionID: caller.id,
            command: command,
            passed: passed,
            summary: request.args["summary"]?.stringValue ?? (passed ? "passed" : "failed"),
            artifacts: request.args["artifacts"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        results(for: project).record(test: result)
        // A failing run moves the task's own state, so the board and the
        // Attention Center show it without waiting for the agent to say more.
        if !passed {
            metadata(for: project).setState(
                .testsFailing, taskID: taskID, detail: result.summary
            )
        }
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "passed": .bool(passed),
                "recorded_at": .string(ISO8601DateFormatter().string(from: result.finishedAt)),
                "artifacts": .array(result.artifacts.map(JSONValue.string)),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func submitTaskReview(
        _ request: ControlRequest,
        caller: SessionRecord
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue,
              let found = findTask(taskID, in: loadDocuments(project)) else {
            return .failure(request, code: .invalidArgument, message: "task not found")
        }
        guard let raw = request.args["verdict"]?.stringValue,
              let verdict = TaskReviewResult.Verdict(rawValue: raw) else {
            return .failure(
                request, code: .invalidArgument,
                message: "'verdict' must be one of: "
                    + TaskReviewResult.Verdict.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        let review = TaskReviewResult(
            taskID: taskID,
            reviewerSessionID: caller.id,
            verdict: verdict,
            findings: request.args["findings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        results(for: project).record(review: review)
        if verdict == .changesRequested {
            metadata(for: project).setState(
                .blocked, taskID: taskID, detail: "the review requested changes"
            )
        }
        // The findings are handed back as the prompt the implementer reads, so
        // the review does not stay locked inside the reviewer's session.
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "verdict": .string(verdict.rawValue),
                "findings": .array(review.findings.map(JSONValue.string)),
                "feedback_prompt": .string(review.feedbackPrompt(
                    taskText: found.task.text, language: agentPromptLanguage)),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func getTaskResults(
        _ request: ControlRequest,
        caller: SessionRecord
    ) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = results(for: project)
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "tests": .array(store.tests(for: taskID).map { test in
                    .object([
                        "command": .string(test.command),
                        "passed": .bool(test.passed),
                        "summary": .string(test.summary),
                        "artifacts": .array(test.artifacts.map(JSONValue.string)),
                        "finished_at": .string(ISO8601DateFormatter().string(from: test.finishedAt)),
                    ])
                }),
                "reviews": .array(store.reviews(for: taskID).map { review in
                    .object([
                        "verdict": .string(review.verdict.rawValue),
                        "findings": .array(review.findings.map(JSONValue.string)),
                        "finished_at": .string(
                            ISO8601DateFormatter().string(from: review.finishedAt)
                        ),
                    ])
                }),
                "merges": .array(store.merges(for: taskID).map { merge in
                    .object([
                        "outcome": .string(merge.outcome.label),
                        "approved_by_user": .bool(merge.approvedByUser),
                        "branch": .string(optional: merge.branch),
                        "at": .string(ISO8601DateFormatter().string(from: merge.at)),
                    ])
                }),
                "completion_blockers": .array(
                    store.completionBlockers(
                        taskID: taskID, settings: orchestratorSettings(for: project)
                    ).map { .string($0.message) }
                ),
            ]),
            project_id: project.id.uuidString
        )
    }

    private func submitForMerge(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let project = taskProject(request, caller: caller) else {
            return .failure(request, code: .permissionDenied, message: "project not accessible")
        }
        guard let taskID = request.args["task_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'task_id' is required")
        }
        let store = metadata(for: project)
        guard let worktree = store.assignments(for: taskID).compactMap(\.worktreePath).first else {
            return .failure(
                request, code: .invalidArgument,
                message: "task has no worktree; call create_task_worktree first"
            )
        }
        // Uncoil reports readiness rather than merging: pushing or merging on an
        // agent's word is the user's call, so the branch and its state are
        // returned and the task is put up for review.
        let snapshot = GitService.snapshot(repoPath: worktree)
        store.setState(.reviewRequested, taskID: taskID, detail: "sent to merge")
        // `userApproved: false` on purpose: an agent asking is not the user
        // approving, so `approvalRequired` always stands in this answer.
        let preview = results(for: project).mergePreview(
            taskID: taskID,
            branch: snapshot.branch,
            changedFiles: snapshot.changedFiles.map(\.path),
            conflictedFiles: GitService.conflictedFiles(repoPath: worktree),
            uncommittedChanges: snapshot.changedFiles.count,
            userApproved: false,
            settings: orchestratorSettings(for: project)
        )
        let record = TaskMergeRecord(
            taskID: taskID,
            branch: snapshot.branch,
            worktreePath: worktree,
            outcome: .refused(
                reason: preview.hardBlockers.isEmpty
                    ? "waiting for the user's approval"
                    : preview.hardBlockers.map(\.message).joined(separator: " ")
            ),
            approvedByUser: false
        )
        results(for: project).record(merge: record)
        return .success(
            request,
            data: .object([
                "task_id": .string(taskID),
                "worktree_path": .string(worktree),
                "branch": .string(optional: snapshot.branch),
                "uncommitted_changes": .int(snapshot.changedFiles.count),
                "merged": .bool(false),
                "ready": .bool(preview.hardBlockers.isEmpty),
                "blockers": .array(preview.blockers.map { .string($0.message) }),
                "changed_files": .array(preview.changedFiles.map(JSONValue.string)),
            ]),
            project_id: project.id.uuidString,
            warnings: snapshot.changedFiles.isEmpty
                ? []
                : ["the worktree has uncommitted changes"],
            next_actions: ["merge with the user's approval"]
        )
    }

    // MARK: - Patch log

    private func taskPatchLogURL() -> URL {
        dataDirectory.appendingPathComponent("task-patches.jsonl")
    }

    /// Stores the diff of every patch made through MCP, so a task's file history
    /// is reviewable without trusting the agent's account of it.
    private func recordTaskPatch(taskID: String?, path: String, diff: String, summary: String) {
        let entry: [String: JSONValue] = [
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "task_id": .string(optional: taskID),
            "path": .string(path),
            "summary": .string(summary),
            "diff": .string(diff),
        ]
        guard var data = try? JSONEncoder().encode(JSONValue.object(entry)) else { return }
        data.append(0x0A)
        let url = taskPatchLogURL()
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func taskPatchLog(taskID: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: taskPatchLogURL().path) else {
            return []
        }
        return data
            .split(separator: 0x0A)
            .compactMap { line -> String? in
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                      let object = value.objectValue,
                      object["task_id"]?.stringValue == taskID else { return nil }
                return object["summary"]?.stringValue
            }
            .reversed()
    }
}

private extension ControlRequest {
    /// Same request, different action — used to reuse an existing handler.
    func replacingAction(_ action: String) -> ControlRequest {
        var copy = self
        copy.action = action
        return copy
    }
}
