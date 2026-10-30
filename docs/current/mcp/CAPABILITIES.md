# MCP control plane — capabilities & actions

Nine MCP tools (capabilities): `uncoil_sessions`, `uncoil_agents`, `uncoil_projects`,
`uncoil_artifacts`, `uncoil_tasks`, `uncoil_run`, `uncoil_system`, `uncoil_browser`,
`uncoil_computer`. Every call is `{"action": "...", ...args}`. Each tool
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
`INVALID_STATE_TRANSITION`, `CONTROL_PLANE_UNAVAILABLE`, `INVALID_ARGUMENT`,
`IO_ERROR`, `INTERNAL_ERROR`, `IDENTITY_UNVERIFIED`, `UNSUPPORTED_CAPABILITY`,
`PROVIDER_UNAVAILABLE`, `IDEMPOTENCY_CONFLICT`, `UNSUPPORTED_VERSION`.

`uncoil_system describe` lists them at runtime, together with every action and
whether it is a `read` or an `effect`.

`CAPABILITY_DISABLED` = the grant is missing (opt-in per session). `PERMISSION_DENIED`
= structurally not allowed. `PERMISSION_REQUIRED` = a user could authorize it via
`uncoil_system request_permission` (details carry `{grant_key, target}`).
`IDENTITY_UNVERIFIED` = the caller could not prove it is the session it names
(`details.reason`: `mismatch` — wrong token, refused for everything; `unverified` —
no token, may read but not act). `UNSUPPORTED_CAPABILITY` = the session is running
but does not offer that operation (see `uncoil_sessions capabilities`).
`PROVIDER_UNAVAILABLE` = the agent is not installed or not ready yet (retryable when
`retryable` says so).

## Reads and effects

Every action is either a **read** or an **effect** (`describe` reports which). An
effect needs a verified caller and passes through one policy gate,
`PolicyEngine.authorize(effect, …)`, with these effects: `read`, `control`
(submit/send_text), `interrupt`, `respond_to_approval`, `create_session`, `resume`,
`close`. An effect sent with `idempotency_key` runs once: a retry with the same key
returns the first answer (with an `idempotent_replay` warning), the same key with
different arguments is `IDEMPOTENCY_CONFLICT`, and a retryable failure is not
remembered.

---

## uncoil_projects

Inspect projects and worktrees, create worktrees, enumerate presets, and read
or write blueprints.

| action | grant | params | returns |
|---|---|---|---|
| `current` | projects.read | — | project of the caller session |
| `context` | projects.read | — | `{context, ssh_hosts:[{alias,note,host_name,user,port,origin,connect}]}` for the caller's project only |
| `list` | projects.read | — | `projects:[{id,name,root_path}]` |
| `inspect` | projects.read | `project_id?` | `{id,name,root_path,repository{is_repo,branch,is_worktree},worktrees,session_ids}` |
| `list_worktrees` | worktrees.read | `project_id?` | `worktrees:[{path,branch,is_main}]` |
| `create_worktree` | **worktrees.create** | `project_id?`, `name` (`[a-zA-Z0-9._-]{1,64}`) | `{path,branch,is_main}` |
| `list_presets` | projects.read | — | `presets:[{id,name,provider,extra_arguments,initial_prompt_template,granted_capabilities,permission_mode}]` |
| `inspect_preset` | projects.read | `preset_id` | one preset object |
| `list_blueprints` | projects.read | — | `blueprints:[{id,name,icon,prompt,starts_immediately,needs_review}]` |
| `inspect_blueprint` | projects.read | `blueprint_id` | one blueprint object |
| `save_blueprint` | **blueprints.write** | `name` (1–60), `prompt` (≤ 8000), `icon?`, `blueprint_id?` | the stored blueprint |
| `delete_blueprint` | **blueprints.write** | `blueprint_id` | `{deleted}` |

`context` is the project context block Uncoil hands an agent at launch (Claude:
`--append-system-prompt`; Codex: `developer_instructions`) — today the SSH hosts
associated with the project in Settings > SSH Hosts — re-read live, so a running
session can pick up hosts added or removed after it started. It never returns
another project's hosts.

A blueprint is a stored prompt a project can be set up from. `blueprints.write`
is opt-in and the caller session must be resolvable, because a blueprint is text
a *later* session gets handed — a session that could write one silently could
leave instructions behind for a session that has not started yet. Anything
written through this surface is stored as a draft: `needs_review` is true and
`starts_immediately` is forced false, so it cannot open a session by itself
until a person has opened and kept it. See `../extensions/BLUEPRINTS.md`.

## uncoil_sessions

Inspect sessions and what they support, read structured timelines and events,
drive sessions through semantic effects, create sessions, coordinate children. The
structured actions work on `AgentSessionControl` and the `AgentEvent` timeline and
never branch on provider: a Codex app-server session and a terminal-only session
answer the same calls, and `capabilities` says what differs.

| action | grant | params | returns |
|---|---|---|---|
| `current` | sessions.read | — | caller's inspect payload |
| `list` | sessions.read (`all` → sessions.read_all) | `all?` | `sessions:[{id,title,provider,status,relation_to_caller}]` |
| `inspect` | sessions.read | `session_id?` | status + `{can_read,can_control,can_close,can_create_child,pending_reports,relation_to_caller}` |
| `read_output` | sessions.read | `session_id?`, `bytes?` (≤262144) | tail of PTY replay; `SESSION_NOT_RUNNING` if no live PTY |
| `capabilities` | sessions.read | `session_id?` | `{running, ready, runtime, supported[], operations{<op>:{supported,via,reason}}, control_capabilities, provider_facts}` |
| `timeline` | sessions.read | `session_id?`, `limit?` (≤500), `before_item_id?`, `text_limit?`, `include_native?` | `{state, items[], has_more, next_before_item_id}` |
| `events` | sessions.read | `session_id?`, `after_sequence?`, `limit?` (≤1000), `wait_s?` (≤120), `include_native?` | `{events[], next_after_sequence, gap, oldest_sequence, sequence, running}` |
| `submit` | effect `control` | `session_id`, `input` (≤16000), `idempotency_key?` | `{accepted, via, after_sequence}`; stale → `SESSION_NOT_RUNNING`, not ready → `PROVIDER_UNAVAILABLE` |
| `interrupt` | effect `interrupt` | `session_id`, `idempotency_key?` | `{interrupted, via}` — the provider's own interrupt, or Ctrl-C for a terminal |
| `respond_approval` | effect `respond_to_approval` (+ **sessions.approve**) | `session_id`, `approval_id`, `decision`, `idempotency_key?` | `{answered}`; terminal-only sessions → `UNSUPPORTED_CAPABILITY` |
| `resume` | effect `resume` | `session_id`, `input?` | starts a stopped session back in its recorded conversation |
| `create_session` | effect `create_session` (**sessions.create_children**) | `provider?`, `account_id?`, `model?`, `effort?`, `working_mode?`, `project_id?`, `worktree_path?`, `initial_prompt?`, `title?`, `preset_id?`, `capabilities?`, `mode?` (`fresh`), `idempotency_key?` | `{session_id, child_session_id, provider, account_id, launch, capabilities, …}` |
| `send_text` | effect `control` | `session_id`, `text`, `raw?` | `{sent_bytes}`; kept for older callers — prefer `submit` |
| `list_children` | sessions.read | `session_id?` | direct children |
| `wait_for_status` | sessions.read | `session_id?`, `status`, `timeout_s?` (≤120) | `{status}` or `TIMEOUT` |
| `stop` | self, or **sessions.control_children** (child) | `session_id?` | SIGTERM; unrelated → `PERMISSION_REQUIRED` |
| `create_child` | **sessions.create_children** | as `create_session`, with `preset_id` required | same as `create_session` |
| `inspect_child` | sessions.read | `session_id` | child inspect; `INVALID_RELATIONSHIP` if not a direct child |
| `wait_for_children` | sessions.read | `session_ids?`, `until` (`completed_or_waiting`), `timeout_s?` (≤300) | `{settled,pending}` or `TIMEOUT` with pending ids |
| `summarize_children` | sessions.read | — | per child `{id,title,status,output_tail(≤2KB),artifact_count}` |
| `report_to_parent` | (child→parent) | `message` (≤8KB), `data?` | appends to parent inbox; `INVALID_RELATIONSHIP` if no parent |
| `read_reports` | (own inbox) | `clear?` | `reports:[{ts,from_session,message,data?}]`, `count` |
| `list_groups` | sessions.read | `project_id?` | project groups, their session ids, and ungrouped session ids |
| `create_group` | **sessions.organize** | `name`, `project_id?` | creates a project session group |
| `rename_group` | **sessions.organize** | `group_id`, `name`, `project_id?` | renames a group |
| `assign_group` | **sessions.organize** | `session_ids`, `group_id?`, `project_id?` | moves sessions into a group; omit `group_id` to ungroup |
| `delete_group` | **sessions.organize** | `group_id`, `project_id?` | deletes the group and leaves its sessions ungrouped |

Settled statuses for `wait_for_children`: `idle`, `waitingForInput`,
`waitingForPermission`, `completed`, `terminated`.

Session operations reported by `capabilities`: `read_output`, `timeline`, `events`,
`submit`, `interrupt`, `respond_approval`, `send_raw`, `resume`. Check
`operations.<op>.supported` rather than the provider name.

`events` is the way to follow work without polling terminal output: pass the
`after_sequence` a `submit` returned, and `wait_s` to wait for the next event.
`gap: true` means events after your sequence were already dropped (the hub keeps the
last 2000 per session) or the timeline was replaced — reread `timeline`. A wait ends
early when the session stops (`running: false`).

`create_session` starts a session exactly as the app does: the same record, launch
selection (model, effort, working mode), account isolation and sidebar row. It never
starts a plain shell, validates `effort` and `working_mode` against what the installed
CLI offers (`uncoil_agents inspect`), and the new session's grants are
`requested ∩ role ∩ caller's own grants`, where the role is `preset_id`'s grants or the
default session profile — never more than the caller holds. The new session is the
caller's child, which is what lets the caller control it without asking the user.

## uncoil_agents

What can be run, before anything is. Both actions need `projects.read`.

| action | params | returns |
|---|---|---|
| `list` | — | `agents:[{provider, display_name, full_name, installed, status_source, control_plane, resumes_conversation, working_modes, accounts:[{id,name,is_default}]}]` |
| `inspect` | `provider` | the `list` entry + `launch:{models, efforts, working_modes, default_model}` |

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
| `status` | — | `{ok,protocol_version,caller_session_id,caller_verification,project_id}` |
| `describe` | — | `{protocol{version,minimum_version}, app_version, features, capabilities[{name,actions[{name,kind,summary}]}], effects, session_operations, error_codes, caller}` — needs no caller |
| `version` | — | `{app_version,protocol_version}` |
| `capabilities` | — | the caller's granted capability strings |
| `doctor` | — | `checks:[{name,ok,detail,remedy}]` |
| `dependencies` | — | agent-browser / cua-driver `{installed,path,version,remedy}` |
| `request_permission` | `grant_key`, `target_session_id?` | creates a pending directional permission request |

## uncoil_run

Project run / dev preview. Configurations live in the repo-owned `.uncoil/run.json`
(the app keeps no hidden copy); detection only appends suggestions and never
overwrites user/agent entries. `id` is optional on get/status/logs/start/stop/
restart — it falls back to the `default: true` configuration (or the only one). All three grants (`runs.read`, `runs.write`,
`runs.control`) are default-on; `runs.control` is flagged risky in the catalog.

| action | grant | params | returns |
|---|---|---|---|
| `list` | runs.read | `project_id?` | configurations + live `state`, `problems`, `total` |
| `detect` | runs.write | `replace?` | merged configurations, `added` ids |
| `get` / `status` | runs.read | `id` | definition + state (pid, issue {code,hint}, log_file), `ports_open`, `preview_url` |
| `logs` | runs.read | `id`, `lines?` | tail under `external_content` (untrusted), `log_file` |
| `start` | runs.control | `id` | starts depends_on chain, waits for readiness; failure = `INVALID_STATE_TRANSITION` + `details.issue`/`log_tail` |
| `stop` / `restart` | runs.control | `id` | lifecycle; SIGTERM→SIGKILL(5s) |
| `update` | runs.write | `configuration` | upsert (marked source=agent, unknown keys preserved; `default: true` moves the default flag) |
| `set_default` | runs.write | `id` | make one configuration the project default (exclusive) |
| `history` | runs.read | `id?`, `limit?` | previous runs `{config_id, started_at, ended_at?, exit_code?, log_file}` (last 10/config kept) |
| `send_input` | runs.control | `id?`, `text`, `raw?` | write to the running process's stdin (e.g. Flutter's `r`) |
| `remove` | runs.write | `id` | refused while starting/running |

Stable `issue.code` values: `port_in_use`, `command_not_found`,
`missing_dependencies`, `invalid_scheme`, `invalid_destination`,
`docker_unavailable`, `build_failed`, `permission_denied`, `exited`, `not_ready`,
`invalid_cwd`, `dependency_failed`, `dependency_cycle`, `unknown_configuration`,
`launch_failed`.

## uncoil_browser / uncoil_computer

Optional, external-CLI-backed. `uncoil_browser` needs `browser.use`
(+`browser.persistent_state` for persistent profiles); `uncoil_computer` grades read
(`computer.inspect`), mutate (`computer.background_control`), and focus-steal
(`computer.foreground_control`). Full action lists in `HelpRegistry.swift`. Both return
page/app content under `external_content` (untrusted) and degrade to
`BROWSER_UNAVAILABLE` / `COMPUTER_UNAVAILABLE` when the CLI is missing.

Browser grants are enabled by default. Computer grants are disabled by default and
must be explicitly enabled by the user. Agent Browser can use Uncoil Chromium or an
installed Chromium-family browser selected in Settings.

`uncoil_browser` also resizes its own session's viewport (`viewport` — `width`,
`height`, optional `scale`) and scrolls an element ref into view
(`scroll_into_view`) before acting on it. Uncoil records the agent-browser release
its command table was verified against (`AgentBrowserAdapter.recommendedVersion`);
an older install still works but `uncoil_system dependencies` reports it with an
update remedy, and Settings › Integrations › Drivers offers the update — only on
the user's click. Older releases drive Playwright's headless shell, newer ones are
a native binary driving Chrome (a detected Chrome/Brave, or one fetched with
`agent-browser install`); the runtime check follows whichever is installed.
