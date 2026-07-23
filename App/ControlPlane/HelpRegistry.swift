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
        for doc in [projects, sessions, artifacts, system] {
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
        let names = ["help", "current", "list", "inspect", "list_worktrees", "create_worktree", "list_presets"]
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
                ActionDoc(action: "list_presets", summary: "Configured project presets (none yet).",
                    doc: "# list_presets\nReturns an empty list for now; presets arrive in a later milestone."),
            ])
    }()

    // MARK: - uncoil_sessions

    static let sessions: CapabilityDoc = {
        let names = ["help", "current", "list", "inspect", "read_output", "send_text",
                     "interrupt", "list_children", "wait_for_status", "stop"]
        let overview = "Inspect agent sessions, read their output, and (for direct children) send input or stop them."
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
                    doc: "# stop\nStops the caller's own session or a direct child (`sessions.control_children`). Args: `session_id` (optional, defaults to caller). Sends SIGTERM via the daemon."),
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
                    doc: "# register\nRequires `artifacts.write`. Args: `name` (required), `kind` (optional), `description` (optional). Appends to `artifacts.json` in the caller's session artifact dir."),
                ActionDoc(action: "resolve_path", summary: "Resolve a name to an approved absolute path.",
                    doc: "# resolve_path\nArgs: `session_id` (optional), `name` (required). Returns the absolute path only if it resolves inside an approved artifact root."),
            ])
    }()

    // MARK: - uncoil_system

    static let system: CapabilityDoc = {
        let names = ["help", "status", "version", "capabilities", "doctor", "dependencies"]
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
                    doc: "# dependencies\nReports agent-browser / cua-driver as `not_integrated_yet`."),
            ])
    }()
}
