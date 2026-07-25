import Foundation

/// Static documentation + the authoritative list of valid actions per
/// capability. The router validates actions against this registry, so adding
/// a handler action without a registry entry (or vice versa) is caught by the
/// help-coverage test.
enum HelpRegistry {
    struct ActionDoc {
        let action: String
        let summary: String
        /// Full markdown-ish documentation returned by `help`.
        let doc: String
    }

    struct CapabilityDoc {
        let capability: String
        /// One short paragraph used as the MCP tool description.
        let overview: String
        let actions: [ActionDoc]

        func action(_ name: String) -> ActionDoc? {
            actions.first { $0.action == name }
        }
        var actionNames: [String] { actions.map(\.action) }
    }

    static let capabilities: [String: CapabilityDoc] = {
        var map: [String: CapabilityDoc] = [:]
        for doc in [projects, sessions, artifacts, tasks, system, browser, computer] {
            map[doc.capability] = doc
        }
        return map
    }()

    static var capabilityNames: [String] { Array(capabilities.keys).sorted() }

    static func actions(for capability: String) -> [String] {
        capabilities[capability]?.actionNames ?? []
    }

    /// One-paragraph tool description + the required "call help" hint.
    static func toolDescription(for capability: String) -> String {
        let overview = capabilities[capability]?.overview ?? capability
        return overview + " Call {\"action\":\"help\"} for full documentation."
    }

    private static func helpAction(_ overview: String, _ actionNames: [String]) -> ActionDoc {
        ActionDoc(
            action: "help",
            summary: "Full documentation for this capability or a single action.",
            doc: """
            # help
            \(overview)

            Actions: \(actionNames.joined(separator: ", ")).

            Usage:
            - `{"action":"help"}` — this overview + every action's docs.
            - `{"action":"help","for_action":"<name>"}` — one action's docs only.
            """
        )
    }

    // MARK: - uncoil_projects

    static let projects: CapabilityDoc = {
        let names = ["help", "current", "list", "inspect", "list_worktrees", "create_worktree",
                     "list_presets", "inspect_preset"]
        let overview = "Inspect Uncoil projects and their git worktrees, and create new worktrees."
        return CapabilityDoc(
            capability: "uncoil_projects",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "current", summary: "The project owning the caller session.",
                    doc: "# current\nResolves the project that owns the calling session (via UNCOIL_SESSION_ID). No args. Returns the same shape as `inspect`."),
                ActionDoc(action: "list", summary: "All registered projects.",
                    doc: "# list\nLists every registered project: `{id, name, root_path}`. No args."),
                ActionDoc(action: "inspect", summary: "Full detail for one project.",
                    doc: "# inspect\nArgs: `project_id` (string, optional — defaults to the caller's project). Returns `{id, name, root_path, repository:{is_repo, branch, is_worktree}, worktrees:[...], session_ids:[...]}`."),
                ActionDoc(action: "list_worktrees", summary: "Git worktrees for a project.",
                    doc: "# list_worktrees\nArgs: `project_id` (optional). Returns `worktrees:[{path, branch, is_main}]`."),
                ActionDoc(action: "create_worktree", summary: "Create a `.uncoil-worktrees/<name>` worktree.",
                    doc: "# create_worktree\nRequires the `worktrees.create` grant. Args: `project_id` (optional), `name` (required, `[a-zA-Z0-9._-]{1,64}`). Creates `<repo>/.uncoil-worktrees/<slug>` on branch `uncoil/<slug>`."),
                ActionDoc(action: "list_presets", summary: "Configured session presets.",
                    doc: "# list_presets\nReturns the configured session presets (or the built-in `claude-worker`/`codex-reviewer` defaults): `presets:[{id, name, provider, extra_arguments, initial_prompt_template, granted_capabilities, permission_mode}]`. Feed a preset `id` to `uncoil_sessions create_child`."),
                ActionDoc(action: "inspect_preset", summary: "Full detail for one preset.",
                    doc: "# inspect_preset\nArgs: `preset_id` (required). Returns the single preset object, or `INVALID_ARGUMENT` if unknown."),
            ])
    }()

    // MARK: - uncoil_sessions

    static let sessions: CapabilityDoc = {
        let names = ["help", "current", "list", "inspect", "read_output", "send_text",
                     "interrupt", "list_children", "wait_for_status", "stop",
                     "create_child", "inspect_child", "wait_for_children",
                     "summarize_children", "report_to_parent", "read_reports",
                     "list_groups", "create_group", "rename_group", "assign_group",
                     "delete_group"]
        let overview = "Inspect agent sessions, read their output, spawn and coordinate child sessions from presets, and (for direct children) send input or stop them."
        return CapabilityDoc(
            capability: "uncoil_sessions",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "current", summary: "The caller's own session.",
                    doc: "# current\nReturns the calling session's `inspect` payload. No args."),
                ActionDoc(action: "list", summary: "Sessions in the caller's project.",
                    doc: "# list\nArgs: `all` (bool, default false — requires the `sessions.read_all` grant to cross projects). Returns `sessions:[{id, title, provider, status, relation_to_caller}]`."),
                ActionDoc(action: "inspect", summary: "Full detail + permissions for one session.",
                    doc: "# inspect\nArgs: `session_id` (optional, defaults to caller). Returns status, `relation_to_caller`, and `{can_read, can_control, can_close, can_create_child}`."),
                ActionDoc(action: "read_output", summary: "Tail of the session's replay buffer.",
                    doc: "# read_output\nArgs: `session_id` (optional), `bytes` (int, default 8192, max 262144). Returns the last N bytes of the PTY replay buffer without attaching. `SESSION_NOT_RUNNING` if the daemon has no live PTY."),
                ActionDoc(action: "send_text", summary: "Send input to a direct-child session.",
                    doc: "# send_text\nRequires `sessions.control_children` and a child relationship. Args: `session_id` (required), `text` (required), `raw` (bool, default false — a newline is appended unless raw)."),
                ActionDoc(action: "interrupt", summary: "Send Ctrl-C to a direct-child session.",
                    doc: "# interrupt\nRequires `sessions.control_children` and a child relationship. Args: `session_id` (required). Sends 0x03."),
                ActionDoc(action: "list_children", summary: "Direct children of a session.",
                    doc: "# list_children\nArgs: `session_id` (optional, defaults to caller). Returns child sessions."),
                ActionDoc(action: "wait_for_status", summary: "Block until a session reaches a status.",
                    doc: "# wait_for_status\nArgs: `session_id` (optional), `status` (required, one of the AgentSessionStatus raw values), `timeout_s` (int, default 30, max 120). Returns `TIMEOUT` on expiry."),
                ActionDoc(action: "stop", summary: "Terminate self or a direct-child session.",
                    doc: "# stop\nStops the caller's own session or a direct child (`sessions.control_children`). Args: `session_id` (optional, defaults to caller). Sends SIGTERM via the daemon. Stopping an unrelated session needs a user permission grant (PERMISSION_REQUIRED)."),
                ActionDoc(action: "create_child", summary: "Spawn a child session from a preset.",
                    doc: "# create_child\nRequires the `sessions.create_children` grant. Args: `preset_id` (required — see uncoil_projects list_presets), `project_id` (optional, defaults to caller's; cross-project needs `sessions.cross_project`), `worktree_path`/`worktree_id` (optional, must be an existing worktree of that project), `initial_prompt` (optional, ≤4000 chars, sanitized), `capabilities` (optional array — intersected with preset.granted_capabilities and the caller's own grants, never escalates), `idempotency_key` (optional — a matching prior child is returned instead of duplicated). NO raw shell commands. Returns `{child_session_id, status, capabilities, …}`. The child appears in the sidebar like any session."),
                ActionDoc(action: "inspect_child", summary: "Inspect a direct child (relationship-checked).",
                    doc: "# inspect_child\nArgs: `session_id` (required). Sugar for `inspect` that requires the target be a direct child (else INVALID_RELATIONSHIP)."),
                ActionDoc(action: "wait_for_children", summary: "Block until children settle.",
                    doc: "# wait_for_children\nArgs: `session_ids` (optional array — defaults to all direct children), `until` (`completed_or_waiting`), `timeout_s` (int ≤300, default 120). Waits until each child status ∈ {idle, waitingForInput, waitingForPermission, completed, terminated}. Returns `TIMEOUT` listing still-pending ids."),
                ActionDoc(action: "summarize_children", summary: "Status + output tail per child.",
                    doc: "# summarize_children\nReturns for each direct child: `{id, title, status, output_tail (≤2 KB), artifact_count}`."),
                ActionDoc(action: "report_to_parent", summary: "Send a one-way report to the parent.",
                    doc: "# report_to_parent\nChild → parent. Args: `message` (required, ≤8 KB), `data` (optional JSON). Appends a JSON line to the parent's `reports/inbox.jsonl`; INVALID_RELATIONSHIP if the caller has no parent."),
                ActionDoc(action: "read_reports", summary: "Read (and optionally clear) the report inbox.",
                    doc: "# read_reports\nArgs: `clear` (bool, default false). Returns `reports:[{ts, from_session, message, data?}]` from the caller's own inbox, clearing it when `clear` is true."),
                ActionDoc(action: "list_groups", summary: "List project session groups.",
                    doc: "# list_groups\nArgs: `project_id` (optional). Returns groups with their session ids and the ungrouped session ids."),
                ActionDoc(action: "create_group", summary: "Create a project session group.",
                    doc: "# create_group\nRequires `sessions.organize`. Args: `name` (required), `project_id` (optional). Returns the new group id."),
                ActionDoc(action: "rename_group", summary: "Rename a session group.",
                    doc: "# rename_group\nRequires `sessions.organize`. Args: `group_id`, `name`, and optional `project_id`."),
                ActionDoc(action: "assign_group", summary: "Move sessions into or out of a group.",
                    doc: "# assign_group\nRequires `sessions.organize`. Args: `session_ids` (required array), `group_id` (optional; omit to ungroup), `project_id` (optional). All sessions must belong to the project."),
                ActionDoc(action: "delete_group", summary: "Delete a group without deleting its sessions.",
                    doc: "# delete_group\nRequires `sessions.organize`. Args: `group_id` and optional `project_id`. Sessions become ungrouped."),
            ])
    }()

    // MARK: - uncoil_artifacts

    static let artifacts: CapabilityDoc = {
        let names = ["help", "list", "inspect", "read_text", "register", "resolve_path"]
        let overview = "List, read, and register text artifacts inside session artifact roots."
        return CapabilityDoc(
            capability: "uncoil_artifacts",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "list", summary: "Artifacts in a session's artifact root.",
                    doc: "# list\nArgs: `session_id` (optional, defaults to caller). Lists files under the session artifact root."),
                ActionDoc(action: "inspect", summary: "Metadata for one artifact.",
                    doc: "# inspect\nArgs: `session_id` (optional), `name` (required). Returns `{name, path, size, modified_at}`."),
                ActionDoc(action: "read_text", summary: "Read a text artifact (≤256 KB).",
                    doc: "# read_text\nArgs: `session_id` (optional), `name` (required). Reads UTF-8 text up to 256 KB. Requires `artifacts.read`; the path must resolve inside an approved session root (symlink escape rejected)."),
                ActionDoc(action: "register", summary: "Record artifact metadata.",
                    doc: "# register\nRequires `artifacts.write`. Args: `name` (required), `kind` (optional), `description` (optional), `status` (optional — `passed`/`failed`). Appends to `artifacts.json` in the caller's session artifact dir. A failed status also raises a row in Uncoil's Attention Center, so report test runs here."),
                ActionDoc(action: "resolve_path", summary: "Resolve a name to an approved absolute path.",
                    doc: "# resolve_path\nArgs: `session_id` (optional), `name` (required). Returns the absolute path only if it resolves inside an approved artifact root."),
            ])
    }()


    // MARK: - uncoil_tasks

    static let tasks: CapabilityDoc = {
        let names = [
            "help",
            "list_todo_files", "list_tasks", "get_task", "get_task_context", "get_board",
            "list_task_sessions", "list_unassigned_tasks", "list_blocked_tasks",
            "list_tasks_by_status", "get_task_diff",
            "create_task", "create_subtask", "update_task", "complete_task", "reopen_task",
            "move_task", "delete_task", "add_task_note",
            "assign_session", "unassign_session",
            "set_task_blocked", "request_task_review", "report_task_progress",
            "complete_task_execution",
            "claim_task", "release_task", "dispatch_task", "spawn_task_agent",
            "wait_for_task_agents", "summarize_task_results",
            "create_task_worktree", "submit_task_for_merge",
            "report_test_result", "submit_task_review", "get_task_results",
        ]
        let overview = """
        Read and edit the project's own TODO.md tasks. The file stays the source of \
        truth: writes are byte-range patches, so formatting, headings and comments \
        survive, and every patch is audited with its diff.
        """
        return CapabilityDoc(
            capability: "uncoil_tasks",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "list_todo_files", summary: "TODO.md sources in the project.",
                    doc: "# list_todo_files\nRequires `tasks.read`. Args: `project_id` (optional). Returns `todo_files:[{path, display_path, task_count, open_task_count, content_hash}]`."),
                ActionDoc(action: "list_tasks", summary: "Tasks, optionally filtered.",
                    doc: "# list_tasks\nRequires `tasks.read`. Args: `source_path`, `heading`, `open_only` (bool), `limit` (≤500). Returns `tasks:[...]` plus `total` and `truncated` — a cap is always reported, never silent."),
                ActionDoc(action: "get_task", summary: "One task with its raw block.",
                    doc: "# get_task\nRequires `tasks.read`. Args: `task_id` (required)."),
                ActionDoc(action: "get_task_context", summary: "The full prompt context for a task.",
                    doc: "# get_task_context\nRequires `tasks.read`. Args: `task_id` (required), `role` (optional). Returns the same prompt Uncoil would send, including the rule that TODO.md formatting must be preserved."),
                ActionDoc(action: "get_board", summary: "Headings as board columns.",
                    doc: "# get_board\nRequires `tasks.read`. Args: `source_path` (optional). Columns come from the file's own headings; an unrecognised heading is its own column."),
                ActionDoc(action: "list_task_sessions", summary: "Task ↔ session assignments.",
                    doc: "# list_task_sessions\nRequires `tasks.read`. Args: `task_id` (optional)."),
                ActionDoc(action: "list_unassigned_tasks", summary: "Tasks nobody is working on.",
                    doc: "# list_unassigned_tasks\nRequires `tasks.read`."),
                ActionDoc(action: "list_blocked_tasks", summary: "Tasks reported blocked or failing.",
                    doc: "# list_blocked_tasks\nRequires `tasks.read`."),
                ActionDoc(action: "list_tasks_by_status", summary: "Tasks by execution status.",
                    doc: "# list_tasks_by_status\nRequires `tasks.read`. Args: `status` (required): all, open, done, assigned, unassigned, running, awaitingReview, blocked."),
                ActionDoc(action: "get_task_diff", summary: "Git state plus the patches Uncoil wrote.",
                    doc: "# get_task_diff\nRequires `tasks.read`. Args: `task_id` (required). Reports the task's worktree (or the project root), its changed files, and the summaries of every patch made through MCP."),
                ActionDoc(action: "create_task", summary: "Add a task under a heading.",
                    doc: "# create_task\nRequires `tasks.write`. Args: `text` (required), `source_path`, `heading`. Inserted after the last task under that heading; nothing else in the file is touched."),
                ActionDoc(action: "create_subtask", summary: "Add a nested task.",
                    doc: "# create_subtask\nRequires `tasks.write`. Args: `parent_task_id` (required), `text` (required). Indented under the parent, using the parent's own list marker."),
                ActionDoc(action: "update_task", summary: "Change a task's text or description.",
                    doc: "# update_task\nRequires `tasks.write`. Args: `task_id` (required), `text`, `description`. Only the task's own line and continuation are rewritten."),
                ActionDoc(action: "complete_task", summary: "Tick the checkbox.",
                    doc: "# complete_task\nRequires `tasks.write`. Args: `task_id`. Changes exactly the three bytes of `[ ]`."),
                ActionDoc(action: "reopen_task", summary: "Clear the checkbox.",
                    doc: "# reopen_task\nRequires `tasks.write`. Args: `task_id`."),
                ActionDoc(action: "move_task", summary: "Move a task under another heading.",
                    doc: "# move_task\nRequires `tasks.write`. Args: `task_id`, `heading`. The whole block moves, children and description included."),
                ActionDoc(action: "delete_task", summary: "Remove a task block.",
                    doc: "# delete_task\nRequires the opt-in `tasks.delete` grant. Args: `task_id`. Removes the block with its children; the diff is stored."),
                ActionDoc(action: "add_task_note", summary: "Append a note to a task.",
                    doc: "# add_task_note\nRequires `tasks.write`. Args: `task_id`, `note`. Existing description lines are kept."),
                ActionDoc(action: "assign_session", summary: "Link a session to a task.",
                    doc: "# assign_session\nRequires `tasks.write`. Args: `task_id`, `session_id` (defaults to caller), `role`, `worktree_path`. Stored in Uncoil's metadata, never in the file."),
                ActionDoc(action: "unassign_session", summary: "Unlink a session.",
                    doc: "# unassign_session\nRequires `tasks.write`. Args: `task_id`, `session_id` (defaults to caller). The task itself is unchanged."),
                ActionDoc(action: "set_task_blocked", summary: "Report a task blocked.",
                    doc: "# set_task_blocked\nRequires `tasks.write`. Args: `task_id`, `reason`. Also available as `mark_task_blocked`."),
                ActionDoc(action: "request_task_review", summary: "Ask for review.",
                    doc: "# request_task_review\nRequires `tasks.write`. Args: `task_id`, `detail`."),
                ActionDoc(action: "report_task_progress", summary: "Report work in flight.",
                    doc: "# report_task_progress\nRequires `tasks.write`. Args: `task_id`, `detail`."),
                ActionDoc(action: "complete_task_execution", summary: "Report execution finished.",
                    doc: "# complete_task_execution\nRequires `tasks.write`. Args: `task_id`. Records the execution state; ticking the checkbox is `complete_task`."),
                ActionDoc(action: "claim_task", summary: "Take an exclusive claim.",
                    doc: "# claim_task\nRequires `tasks.write`. Args: `task_id`, `duration_seconds` (60…3600). Fails while another session holds a live claim; the same session renews."),
                ActionDoc(action: "release_task", summary: "Give up a claim.",
                    doc: "# release_task\nRequires `tasks.write`. Args: `task_id`."),
                ActionDoc(action: "dispatch_task", summary: "Start an agent on a task.",
                    doc: "# dispatch_task\nRequires the opt-in `tasks.orchestrate` grant. Args: `task_id`, `role`, `preset_id`, `worktree_path`. Creates a child through the preset path, so its capabilities are the preset intersected with yours — never more. Same as `spawn_task_agent`."),
                ActionDoc(action: "wait_for_task_agents", summary: "Check whether a task's agents settled.",
                    doc: "# wait_for_task_agents\nRequires `tasks.orchestrate`. Args: `task_id`. Returns immediately with `settled` and what is still pending — polling, because a blocking wait would hold the control socket."),
                ActionDoc(action: "summarize_task_results", summary: "Assignments and history for a task.",
                    doc: "# summarize_task_results\nRequires `tasks.orchestrate`. Args: `task_id`."),
                ActionDoc(action: "spawn_task_agent", summary: "Alias of dispatch_task.",
                    doc: "# spawn_task_agent\nIdentical to `dispatch_task`; both require `tasks.orchestrate`."),
                ActionDoc(action: "mark_task_blocked", summary: "Alias of set_task_blocked.",
                    doc: "# mark_task_blocked\nIdentical to `set_task_blocked`; both require `tasks.write`."),
                ActionDoc(action: "create_task_worktree", summary: "Cut a worktree for a task.",
                    doc: "# create_task_worktree\nRequires the opt-in `tasks.worktree` grant. Args: `task_id`, `name` (optional)."),
                ActionDoc(action: "submit_task_for_merge", summary: "Report a task ready to merge.",
                    doc: "# submit_task_for_merge\nRequires the opt-in `tasks.merge` grant. Args: `task_id`. Uncoil does NOT merge or push: it reports the branch, the changed files and every remaining blocker, records the attempt in the merge audit, and puts the task up for review — merging stays the user's decision."),
                ActionDoc(action: "report_test_result", summary: "Record a test run for a task.",
                    doc: "# report_test_result\nRequires `tasks.write`. Args: `task_id`, `command`, `passed` (bool), `summary`, `artifacts` (array of names). A failing run is remembered and blocks `complete_task` until a later run passes."),
                ActionDoc(action: "submit_task_review", summary: "Record a review verdict.",
                    doc: "# submit_task_review\nRequires `tasks.write`. Args: `task_id`, `verdict` (approved|changesRequested|commented), `findings` (array). Returns `feedback_prompt` — the message to hand back to the implementation session. `changesRequested` marks the task blocked."),
                ActionDoc(action: "get_task_results", summary: "Tests, reviews and merge attempts.",
                    doc: "# get_task_results\nRequires `tasks.read`. Args: `task_id`. Returns every recorded test run, review verdict and merge attempt, plus the blockers that stand between the task and a ticked checkbox."),
            ])
    }()

    // MARK: - uncoil_system

    static let system: CapabilityDoc = {
        let names = ["help", "status", "version", "capabilities", "doctor", "dependencies",
                     "request_permission"]
        let overview = "Report Uncoil control-plane status, version, granted capabilities, and health diagnostics."
        return CapabilityDoc(
            capability: "uncoil_system",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "status", summary: "Control-plane liveness summary.",
                    doc: "# status\nReturns `{ok, protocol_version, caller_session_id, project_id}`."),
                ActionDoc(action: "version", summary: "App + protocol version.",
                    doc: "# version\nReturns `{app_version, protocol_version}`."),
                ActionDoc(action: "capabilities", summary: "The caller's capability grants.",
                    doc: "# capabilities\nReturns the caller session's granted capability strings."),
                ActionDoc(action: "doctor", summary: "Per-check health diagnostics.",
                    doc: "# doctor\nRuns checks (control socket, runtime daemon, git, data dir, hook server) returning `{name, ok, detail, remedy}` for each."),
                ActionDoc(action: "dependencies", summary: "External driver integration status.",
                    doc: "# dependencies\nReports the optional external drivers `agent-browser` and `cua-driver` with `{installed, path, version, remedy}` (or `not_installed`)."),
                ActionDoc(action: "request_permission", summary: "Ask the user to authorize a denied action.",
                    doc: "# request_permission\nArgs: `grant_key` (required — e.g. `sessions.control`, `sessions.close`), `target_session_id` (optional). Creates a pending, directional (caller→target) permission request the user approves/denies in Uncoil → Settings → İzinler. Grants are revocable and pending requests auto-expire after 10 minutes."),
            ])
    }()

    // MARK: - uncoil_browser

    static let browser: CapabilityDoc = {
        let names = ["help", "status", "start", "stop", "open", "navigate", "back", "reload",
                     "snapshot", "click", "fill", "type", "press", "hover", "select", "scroll",
                     "wait", "get", "screenshot", "list_tabs", "new_tab", "switch_tab",
                     "close_tab", "save_state", "clear_state"]
        let overview = "Drive an isolated headless browser (via the optional agent-browser CLI) to open pages, snapshot the accessibility tree, and act on stable element refs. Requires the browser.use grant; degrades to BROWSER_UNAVAILABLE when agent-browser is not installed."
        return CapabilityDoc(
            capability: "uncoil_browser",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "status", summary: "Browser session identity + engine availability.",
                    doc: "# status\nReturns `{browser_session_id, installed, profile_mode, allowed_domains, blocked_domains, engine}`. No side effects."),
                ActionDoc(action: "start", summary: "Initialize the isolated browser session.",
                    doc: "# start\nArgs: `profile_mode` (ephemeral_session|persistent_session|persistent_project — persistent modes need browser.persistent_state), `allowed_domains`/`blocked_domains` (string arrays). Establishes the derived session id `uncoil-<pid8>-<sid8>`."),
                ActionDoc(action: "stop", summary: "Close the caller's own browser session.",
                    doc: "# stop\nCloses only the caller's derived browser session — never another session's."),
                ActionDoc(action: "open", summary: "Open a URL (subject to domain policy).",
                    doc: "# open\nArgs: `url` (required). Enforces allowed/blocked domain policy → PERMISSION_DENIED on violation."),
                ActionDoc(action: "navigate", summary: "Navigate to a URL (alias of open).",
                    doc: "# navigate\nArgs: `url` (required). Same domain policy as `open`."),
                ActionDoc(action: "back", summary: "Go back in history.", doc: "# back\nNo args."),
                ActionDoc(action: "reload", summary: "Reload the page.", doc: "# reload\nNo args."),
                ActionDoc(action: "snapshot", summary: "Accessibility snapshot with element refs.",
                    doc: "# snapshot\nArgs: `interactive_only` (bool). Returns the tree under `external_content` (untrusted) with stable refs like `@e1` to use in click/fill/hover."),
                ActionDoc(action: "click", summary: "Click an element ref.",
                    doc: "# click\nArgs: `ref` (required, e.g. `@e2`). A stale/unknown ref → STALE_ELEMENT_REFERENCE; take a fresh snapshot."),
                ActionDoc(action: "fill", summary: "Clear and fill an input.",
                    doc: "# fill\nArgs: `ref`, `text` (both required)."),
                ActionDoc(action: "type", summary: "Type into an element.",
                    doc: "# type\nArgs: `ref`, `text` (both required)."),
                ActionDoc(action: "press", summary: "Press a key.",
                    doc: "# press\nArgs: `keys` (required, e.g. `Enter`, `Control+a`)."),
                ActionDoc(action: "hover", summary: "Hover an element ref.",
                    doc: "# hover\nArgs: `ref` (required)."),
                ActionDoc(action: "select", summary: "Select a dropdown option.",
                    doc: "# select\nArgs: `ref`, `value` (both required)."),
                ActionDoc(action: "scroll", summary: "Scroll the page.",
                    doc: "# scroll\nArgs: `direction` (up/down/left/right, default down), `amount` (px, optional)."),
                ActionDoc(action: "wait", summary: "Wait for a selector or milliseconds.",
                    doc: "# wait\nArgs: `selector` (CSS) or `ms` (int). Defaults to 1000ms."),
                ActionDoc(action: "get", summary: "Read page/element info.",
                    doc: "# get\nArgs: `what` (url|title|text|html|value|…, default url), `ref` (optional). Content returns under `external_content`."),
                ActionDoc(action: "screenshot", summary: "Capture a screenshot artifact.",
                    doc: "# screenshot\nArgs: `full_page` (bool). Writes a timestamped PNG under the session's browser/screenshots and registers it in artifacts."),
                ActionDoc(action: "list_tabs", summary: "List open tabs.", doc: "# list_tabs\nNo args."),
                ActionDoc(action: "new_tab", summary: "Open a new tab.",
                    doc: "# new_tab\nArgs: `url` (optional)."),
                ActionDoc(action: "switch_tab", summary: "Switch to a tab by index.",
                    doc: "# switch_tab\nArgs: `index` (required, int)."),
                ActionDoc(action: "close_tab", summary: "Close a tab.",
                    doc: "# close_tab\nArgs: `index` (optional; current tab if omitted)."),
                ActionDoc(action: "save_state", summary: "Persist cookies/state to an artifact.",
                    doc: "# save_state\nRequires browser.persistent_state. Writes a state JSON artifact under browser/states."),
                ActionDoc(action: "clear_state", summary: "Clear the caller's browser state.",
                    doc: "# clear_state\nClears only the caller's own derived session state — never another session's."),
            ])
    }()

    // MARK: - uncoil_computer

    static let computer: CapabilityDoc = {
        let names = ["help", "status", "doctor", "permissions", "list_apps", "launch_app",
                     "list_windows", "inspect_window", "snapshot", "click", "double_click",
                     "right_click", "type", "press", "hotkey", "scroll", "screenshot", "bring_to_front"]
        let overview = "Inspect and control native macOS apps (via the optional cua-driver CLI) through a per-session window binding. Read actions need computer.inspect, mutating actions computer.background_control, and focus-stealing bring_to_front needs computer.foreground_control. Degrades to COMPUTER_UNAVAILABLE when cua-driver is not installed."
        return CapabilityDoc(
            capability: "uncoil_computer",
            overview: overview,
            actions: [
                helpAction(overview, names),
                ActionDoc(action: "status", summary: "Engine availability + current window binding.",
                    doc: "# status\nReturns `{installed, engine, has_binding, binding}`. Works even when cua-driver is not installed."),
                ActionDoc(action: "doctor", summary: "cua-driver self-diagnostics.",
                    doc: "# doctor\nRuns the driver's doctor. Requires computer.inspect."),
                ActionDoc(action: "permissions", summary: "Accessibility/Screen-Recording status.",
                    doc: "# permissions\nReports the driver's permission state. Requires computer.inspect."),
                ActionDoc(action: "list_apps", summary: "Running/known applications.",
                    doc: "# list_apps\nRequires computer.inspect. Content returns under `external_content`."),
                ActionDoc(action: "launch_app", summary: "Launch an application.",
                    doc: "# launch_app\nArgs: `bundle_id` (required). Requires computer.background_control."),
                ActionDoc(action: "list_windows", summary: "Windows for an app.",
                    doc: "# list_windows\nArgs: `bundle_id` (optional). Requires computer.inspect."),
                ActionDoc(action: "inspect_window", summary: "Establish a window binding.",
                    doc: "# inspect_window\nArgs: `bundle_id` (required), `window_id` (optional). Establishes the per-session binding `{bundle_id, pid, window_id, title, generation}` required by mutating actions."),
                ActionDoc(action: "snapshot", summary: "Accessibility snapshot of the bound window.",
                    doc: "# snapshot\nArgs: `bundle_id`/`window_id` to (re)bind, or none to reuse the current binding. Content returns under `external_content` (untrusted)."),
                ActionDoc(action: "click", summary: "Click an AX element or window coordinates.",
                    doc: "# click\nArgs: `element_index` from the latest snapshot (preferred), or both `x` and `y` in window-local screenshot pixels. Acts on the bound window without fronting it. Requires computer.background_control; STALE_WINDOW_BINDING if the window is gone."),
                ActionDoc(action: "double_click", summary: "Double-click an AX element or window coordinates.",
                    doc: "# double_click\nArgs: `element_index` (preferred), or both `x` and `y`. Bound window only."),
                ActionDoc(action: "right_click", summary: "Right-click an AX element or window coordinates.",
                    doc: "# right_click\nArgs: `element_index` (preferred), or both `x` and `y`. Bound window only."),
                ActionDoc(action: "type", summary: "Type text into the bound window.",
                    doc: "# type\nArgs: `text` (required), plus optional `element_index` from the latest snapshot or both `x` and `y`. Prefer `element_index` for background text fields. Without a target, types into the focused element of the bound window."),
                ActionDoc(action: "press", summary: "Press a key in the bound window.",
                    doc: "# press\nArgs: `keys` (required). Bound window only."),
                ActionDoc(action: "hotkey", summary: "Send a hotkey chord to the bound window.",
                    doc: "# hotkey\nArgs: `keys` (required, e.g. `cmd+s`). Bound window only."),
                ActionDoc(action: "scroll", summary: "Scroll the bound window.",
                    doc: "# scroll\nArgs: `direction` (default down), `amount` (optional). Bound window only."),
                ActionDoc(action: "screenshot", summary: "Capture a screenshot artifact.",
                    doc: "# screenshot\nCaptures the bound window (or screen). Writes a timestamped PNG under computer/screenshots and registers it. Requires computer.inspect."),
                ActionDoc(action: "bring_to_front", summary: "Focus the bound window (intrusive).",
                    doc: "# bring_to_front\nRequires computer.foreground_control. Steals focus; returns a warning and is audited."),
            ])
    }()
}
