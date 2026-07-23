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
        for doc in [projects, sessions, artifacts, system, browser, computer] {
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
                    doc: "# dependencies\nReports the optional external drivers `agent-browser` and `cua-driver` with `{installed, path, version, remedy}` (or `not_installed`)."),
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
                ActionDoc(action: "click", summary: "Click at window coordinates.",
                    doc: "# click\nArgs: `x`, `y` (required). Acts on the bound window (never the frontmost implicitly). Requires computer.background_control; STALE_WINDOW_BINDING if the window is gone."),
                ActionDoc(action: "double_click", summary: "Double-click at window coordinates.",
                    doc: "# double_click\nArgs: `x`, `y` (required). Bound window only."),
                ActionDoc(action: "right_click", summary: "Right-click at window coordinates.",
                    doc: "# right_click\nArgs: `x`, `y` (required). Bound window only."),
                ActionDoc(action: "type", summary: "Type text into the bound window.",
                    doc: "# type\nArgs: `text` (required). Bound window only."),
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
