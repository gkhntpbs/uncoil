# MCP control plane — capabilities & actions

Six MCP tools (capabilities). Every call is `{"action": "...", ...args}`. Each tool
also exposes `{"action":"help"}` (whole tool) and `{"action":"help","for_action":"x"}`
(one action) — the authoritative, always-current docs live in `HelpRegistry.swift`;
this file summarizes them.

## Envelope

Success: `{ok:true, capability, action, request_id, project_id?, caller_session_id?,
target_session_id?, data, artifacts:[], warnings:[], next_actions:[]}`.
Failure: `{ok:false, ..., error:{code, message, retryable, details?}}`.

## Error codes (stable strings; never renamed)

`UNKNOWN_PROJECT`, `UNKNOWN_SESSION`, `SESSION_NOT_RUNNING`, `CAPABILITY_DISABLED`,
`PERMISSION_REQUIRED`, `PERMISSION_DENIED`, `INVALID_RELATIONSHIP`, `INVALID_PATH`,
`BROWSER_UNAVAILABLE`, `COMPUTER_UNAVAILABLE`, `STALE_ELEMENT_REFERENCE`,
`STALE_WINDOW_BINDING`, `TARGET_CHANGED`, `TIMEOUT`, `CANCELLED`,
`DEPENDENCY_VERSION_MISMATCH`, `UNSUPPORTED_PLATFORM`, `INVALID_ACTION`,
`INVALID_STATE_TRANSITION`, `CONTROL_PLANE_UNAVAILABLE`, `INVALID_ARGUMENT`.

`CAPABILITY_DISABLED` = the grant is missing (opt-in per session). `PERMISSION_DENIED`
= structurally not allowed. `PERMISSION_REQUIRED` = a user could authorize it via
`uncoil_system request_permission` (details carry `{grant_key, target}`).

---

## uncoil_projects

Inspect projects and worktrees, create worktrees, and enumerate presets.

| action | grant | params | returns |
|---|---|---|---|
| `current` | projects.read | — | project of the caller session |
| `list` | projects.read | — | `projects:[{id,name,root_path}]` |
| `inspect` | projects.read | `project_id?` | `{id,name,root_path,repository{is_repo,branch,is_worktree},worktrees,session_ids}` |
| `list_worktrees` | worktrees.read | `project_id?` | `worktrees:[{path,branch,is_main}]` |
| `create_worktree` | **worktrees.create** | `project_id?`, `name` (`[a-zA-Z0-9._-]{1,64}`) | `{path,branch,is_main}` |
| `list_presets` | projects.read | — | `presets:[{id,name,provider,extra_arguments,initial_prompt_template,granted_capabilities,permission_mode}]` |
| `inspect_preset` | projects.read | `preset_id` | one preset object |

## uncoil_sessions

Inspect sessions, read output, spawn/coordinate children, control direct children.

| action | grant | params | returns |
|---|---|---|---|
| `current` | sessions.read | — | caller's inspect payload |
| `list` | sessions.read (`all` → sessions.read_all) | `all?` | `sessions:[{id,title,provider,status,relation_to_caller}]` |
| `inspect` | sessions.read | `session_id?` | status + `{can_read,can_control,can_close,can_create_child,pending_reports,relation_to_caller}` |
| `read_output` | sessions.read | `session_id?`, `bytes?` (≤262144) | tail of PTY replay; `SESSION_NOT_RUNNING` if no live PTY |
| `send_text` | **sessions.control_children** (child) | `session_id`, `text`, `raw?` | `{sent_bytes}`; non-child → `PERMISSION_REQUIRED` |
| `interrupt` | **sessions.control_children** (child) | `session_id` | sends 0x03 |
| `list_children` | sessions.read | `session_id?` | direct children |
| `wait_for_status` | sessions.read | `session_id?`, `status`, `timeout_s?` (≤120) | `{status}` or `TIMEOUT` |
| `stop` | self, or **sessions.control_children** (child) | `session_id?` | SIGTERM; unrelated → `PERMISSION_REQUIRED` |
| `create_child` | **sessions.create_children** | `preset_id`, `project_id?` (cross → **sessions.cross_project**), `worktree_path?`/`worktree_id?`, `initial_prompt?` (≤4000), `capabilities?`, `idempotency_key?` | `{child_session_id,status,capabilities,…}` |
| `inspect_child` | sessions.read | `session_id` | child inspect; `INVALID_RELATIONSHIP` if not a direct child |
| `wait_for_children` | sessions.read | `session_ids?`, `until` (`completed_or_waiting`), `timeout_s?` (≤300) | `{settled,pending}` or `TIMEOUT` with pending ids |
| `summarize_children` | sessions.read | — | per child `{id,title,status,output_tail(≤2KB),artifact_count}` |
| `report_to_parent` | (child→parent) | `message` (≤8KB), `data?` | appends to parent inbox; `INVALID_RELATIONSHIP` if no parent |
| `read_reports` | (own inbox) | `clear?` | `reports:[{ts,from_session,message,data?}]`, `count` |

Settled statuses for `wait_for_children`: `idle`, `waitingForInput`,
`waitingForPermission`, `completed`, `terminated`.

`create_child` never accepts raw shell commands — the provider, arguments, and the
grantable capability ceiling all come from the named preset. The effective child grants
= `requested ∩ preset.granted_capabilities ∩ caller's own grants` (never escalates).

## uncoil_artifacts

Session-scoped text artifacts (path-contained, symlink-safe).

| action | grant | params | returns |
|---|---|---|---|
| `list` | artifacts.read (cross-session) | `session_id?` | `artifacts:[{name,size}]` |
| `inspect` | artifacts.read | `session_id?`, `name` | `{name,path,size,modified_at}` |
| `read_text` | artifacts.read | `session_id?`, `name` | UTF-8 text ≤256 KB |
| `register` | **artifacts.write** | `name`, `kind?`, `description?` | appends to `artifacts.json` |
| `resolve_path` | artifacts.read | `session_id?`, `name` | contained absolute path or `INVALID_PATH` |

## uncoil_system

| action | params | returns |
|---|---|---|
| `status` | — | `{ok,protocol_version,caller_session_id,project_id}` |
| `version` | — | `{app_version,protocol_version}` |
| `capabilities` | — | the caller's granted capability strings |
| `doctor` | — | `checks:[{name,ok,detail,remedy}]` |
| `dependencies` | — | agent-browser / cua-driver `{installed,path,version,remedy}` |
| `request_permission` | `grant_key`, `target_session_id?` | creates a pending directional permission request |

## uncoil_browser / uncoil_computer

Optional, external-CLI-backed. `uncoil_browser` needs `browser.use`
(+`browser.persistent_state` for persistent profiles); `uncoil_computer` grades read
(`computer.inspect`), mutate (`computer.background_control`), and focus-steal
(`computer.foreground_control`). Full action lists in `HelpRegistry.swift`. Both return
page/app content under `external_content` (untrusted) and degrade to
`BROWSER_UNAVAILABLE` / `COMPUTER_UNAVAILABLE` when the CLI is missing.
