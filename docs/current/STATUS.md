# Uncoil — Status and Roadmap

> Last updated: 2026-07-25 · Tests: 198/198 unit+integration + 8/8 UI + the Computer Use acceptance flow
> This is what `docs/roadmap/FOUNDATION_PLAN.md` looks like once reality is applied to it.
> A new session should read this file first, then the relevant agent instructions.

## Deviations from the plan (deliberate decisions)

| What the plan said | What was done | Why |
|---|---|---|
| Build on an existing codebase | **Our own codebase, from scratch.** GPL code is never copied | Decision (2026-07-23): "I don't want to build on top of an existing project". The license stayed entirely ours |
| Ghostty terminal engine | **SwiftTerm (MIT, SPM)** | zig 0.15.2 will not link against the macOS 26.5 SDK; SwiftTerm is enough and gives no trouble |
| GPL-3.0 distribution obligation | Does not apply — the single dependency is MIT | The fork was abandoned |
| Xcode project by hand | **XcodeGen** (`project.yml` → generate) | Reproducibility; `Uncoil.xcodeproj` is gitignored |
| Milestone order (§27) | A flexible order, led by product feedback | The user tested live and steered |
| Persistent runtime = LaunchAgent (§12) | **On-demand daemon** (`uncoil-runtimed`, embedded in the bundle; the app spawns it when it finds no socket, and setsid keeps it alive independently of the app) | Registering a LaunchAgent (SMAppService + a Login Items approval) is needless friction for v1; if the daemon crashes the PTYs die anyway, so a launchd restart adds nothing. SMAppService can be added later |

## Done ✅

### Core
- **Project/session model + persistence** — `projects.json` / `sessions.json` (App Support/Uncoil), written atomically
- **Terminal infrastructure** — one PTY per session (SwiftTerm), the agent starts directly through `exec` (the command stays invisible), HOME/PATH corrected in the PTY's environment, a dead session restarts when selected (Claude with `--resume`, so it keeps its history)
- **CLI resolution** — known install directories plus an interactive login shell; a path that disappears is resolved again automatically
- **Claude hook bridge** — the `uncoil-hook` helper (embedded in the bundle) → a Unix socket (0600) → the state reducer; installed into `~/.claude/settings.json` with a backup, atomically and reversibly (Settings → Hooks)
- **An honest state machine** — Ready / Thinking / Running (tool) / Waiting for permission / Waiting for a reply / Closed; titles come from the first prompt automatically

### Persistent runtime ("terminals that never die", plan §12 — v1)
- **`uncoil-runtimed`**: a separate daemon that owns the PTYs (`RuntimeHelper/`, a tool target, embedded in Resources). Agent processes survive the app closing or crashing
- IPC: a line-JSON protocol over `App Support/Uncoil/runtime.sock` (0600) (`Shared/RuntimeProtocol.swift`, major/minor negotiation); every peer passes a LOCAL_PEERCRED euid check. An incompatible major version produces a plain user-facing error
- Daemon: single-instance file lock, openpty + posix_spawn (SETSID + CLOEXEC_DEFAULT; the slave opened as fd0 for a controlling tty), disk-bounded replay at 512 KB per session / 16 MB total, 1 MB × 3 rotating logs, child reaping/idle detection, NOFILE/core limits and a graceful upgrade drain
- App: `RuntimeClient` handles the heartbeat, bounded exponential crash restart and sleep/wake reconnect; `TerminalRegistry` uses the daemon-backed `TerminalView`. If the daemon is unreachable it falls back to the old in-process PTY. Off in UI tests for determinism (turned on with `-runtime`)
- Verification: the terminal persistence/replay flow in the real app; integration tests against a real `uncoil-runtimed` binary for handshake, heartbeat, version mismatch, graceful upgrade, single-instance, crash restart, child reaping, the replay disk limit, log rotation and sleep/wake reconnect; the runtime-mismatch warning covered by a Computer Use acceptance test

### App lifecycle
- **Quit policy** — persistent “Keep sessions running” and “Terminate all agents on quit” options under Settings → Agent Settings; the safe default keeps sessions alive inside the daemon
- The termination decision reaches the runtime queue synchronously; terminate closes the daemon and every process group, keep drops only the app's connection
- The runtime daemon stays single-instance per socket through `flock`; a second daemon cannot take over a live socket
- With the main window closed, a Dock click or a second launch recreates the SwiftUI `WindowGroup` scene; ⌘N uses the same reliable path
- The main window's position and size are restored through AppKit frame autosave, and the last project/group/session selection is restored after checking the record is still valid; UI fixtures do not disturb the real user's restoration state
- Verification: two quit-policy tests against a real daemon, a daemon single-instance test, 6/6 XCUITests, and Computer Use confirming that a closed `main-AppWindow-1` comes back as `main-AppWindow-2`

### Session system
- Closed sessions are kept with their exit metadata in a separate history panel; reopening returns them to the active list and updates the restart counter
- Session records are stored in a versioned `SessionDocument`; the old flat-array format migrates safely, and unknown future versions are not downgraded
- Claude resumes with `--resume` and the hook session id, Codex with `codex resume` and the rollout `session_meta` id; Codex matching is confined to the account root and the exact working directory
- Agent Settings holds a persistent session-preset editor for the provider, CLI arguments, opening prompt, permission mode and capability bounds
- Terminal transcript recording is off by default; 7 days, 30 days or indefinite retention can be chosen. Files are written 0600, off the main UI thread; every sensitive transcript can be deleted in one confirmed action
- Verification: migration, future-schema, history/restart, resume commands, Codex metadata matching, preset persistence, transcript retention/prune/clear tests; 8/8 XCUITests, plus Computer Use covering history → Codex resume, a populated preset editor and the transcript-clearing confirmation

### MCP control plane (plan §16–17 — agent collaboration)
- **Six MCP tools** open a bounded surface to agents: `uncoil_projects / uncoil_sessions / uncoil_artifacts / uncoil_system / uncoil_browser / uncoil_computer`. Every session gets the bundled `uncoil-mcp` stdio server registered; it reaches the in-app control plane over `control.sock` (0600 + a euid check) with line-JSON. The wire shapes live in one place (`Shared/ControlProtocol.swift`), compiled into both the app and `uncoil-mcp`
- **Layers:** `ControlPlaneServer` → `CapabilityRouter` → the pure `PolicyEngine` (grant/relationship decisions) + `PermissionService` (directional user permissions) + the handlers; every request is written to the audit log (`audit/*.jsonl`, argument keys only)
- **Orchestration (M5):** `create_child` accepts NO raw shell — only named `SessionPreset`s (the built-in `claude-worker` / `codex-reviewer`); capabilities are narrowed by intersection (preset ∩ caller, never escalating), and idempotency_key prevents duplicates. A child session appears in the sidebar like any other. Child coordination: `inspect_child`, `wait_for_children` (waits for a settled state, with TIMEOUT), `summarize_children` (state + output tail + artifact count), and one-way `report_to_parent` / `read_reports` (the parent's inbox.jsonl; `pending_reports` in inspect)
- **Permission flow:** controlling a sibling or an unrelated session → `PERMISSION_REQUIRED`; the agent calls `uncoil_system request_permission`, and the user approves, denies or revokes in **Settings → Permissions**. Permissions are directional (A→B does not cover C→B), revocable, and rechecked on every call (never cached); pending ones expire after 10 minutes. `permissions.json` is written atomically
- **Hardening (M6):** waits do not block the socket (each request is its own `Task { @MainActor }`, and `Task.sleep` releases the actor); `permissions.json` / `artifacts.json` use write-temp-rename (`AtomicFile`)
- **Documentation:** `docs/current/mcp/` (ARCHITECTURE / CAPABILITIES / PERMISSIONS / ARTIFACTS / SECURITY / TROUBLESHOOTING). 198/198 tests pass in the `UncoilTests` bundle; all six MCP tools passed acceptance over a real control socket

### Multiple accounts
- An isolated config root per profile: `CLAUDE_CONFIG_DIR` / `CODEX_HOME` (profiles/<provider>/<name>)
- **Sign in with a browser**: "Sign In" on a profile → `claude /login` / `codex login` in an embedded terminal; credentials never pass through Uncoil
- Login detection: Claude's `.claude.json` oauthAccount; Codex's `auth.json` (the JWT email)

### UI (an original language, Unpeel-inspired)
- Titleless window, a single dark surface, mono typography, the Tabler Icons webfont (5016 icons)
- Sidebar: project rows (customisable icon + colour + name), an agent-launch strip on hover, session sub-rows (AI marks: Claude ✳ / OpenAI), pinning, drag-to-reorder, per-project and bulk hide/show, ⌘B plus edge-drag to resize or hide
- **Project dashboard**: sessions, the worktree list and creation (`.uncoil-worktrees/<slug>`, starting an agent inside a worktree), git status and commits, the PR panel (GitHub), the file tree
- **Session view**: the control cluster — editor (the real app icon plus a menu of installed editors), restart, and the Changes panel on the right (click a file → open it in the editor)
- Open a session **in its own window** (sharing the PTY) and **drag-and-drop split** (two sessions side by side)
- **Session groups** — persistent groups under a project, a management view for the group, multiple selection, bulk prompt/interrupt/restart/delete, multi drag-and-drop and bulk deletion
- **Organise automatically** — the shortcut on the project dashboard starts a Claude session; the agent arranges the sessions by purpose through Uncoil's MCP group tools
- Status orb animations, custom scroll bars, a custom folder picker, delete confirmation

### Settings (native macOS, categorised and searchable)
- macOS's own settings language: a source list plus `Form(.grouped)` pages, the system font and controls, a resizable window, and rows that move the control under the label when the window is narrow. Search matches **the settings inside a page**, not page titles; the old deep links (`defaults`, `transcripts`…) still resolve
- **General** (default agent, editor, quit behaviour, interface and agent language, command-palette shortcut) · **Agents** (Accounts / CLI Tools / Parameters / Mode and Keyboard / Session Presets) · **Notifications** (General / Events / Reminders / Quiet Hours / Per Project) · **Menu Bar** · **Appearance** · **Privacy and Permissions** (Permissions / Data and Transcripts / Status Tracking) · **Integrations** (GitHub / Drivers) · **About**
- **Notifications are per event** — permission, input, turn done, error, task done, merge ready, login needed: each carries its own on/off, priority and sound (resolved event → project → global). Delivery filters: notify only while in the background, stay quiet about the session on screen, group by project
- **Reminders** — states that last until the user acts (waiting for input or permission, a dropped login, ready to merge) are announced again at a configurable interval and count; the session's current state is re-read before each repeat, so something already resolved is not reminded about
- **Quiet hours** — including windows that wrap past midnight; high-priority events can be let through if wanted
- **Menu-bar settings** — icon style (the Uncoil mark / an SF Symbol / counters alone), single colour, which counters appear (running, waiting, problems, tasks), hide while idle, which sections the menu carries; with a live preview
- **Language** — the interface language (system / English / Turkish) and, separately, the language Uncoil writes agent prompts in; the interface language applies after a relaunch
- Private-repo PRs with a GitHub token; background Keychain reads are non-interactive and open no password window
- **Permissions** — shows the common permissions in four understandable groups; project/session/browser automation is on by default, and only Computer Use is necessarily off and requires approval
- **Agent Browser choice** — only Chromium-based browsers installed on the machine are listed; Uncoil supports Chromium, Chrome, Arc, Edge, Brave, Vivaldi
- **Provider working modes** — the working mode new sessions use for Claude and Codex is chosen in Agent Settings; it supports Claude's Manual/Accept Edits/Plan/Auto/Dangerously Skip Permissions and Codex's Ask for Approval/Approve for Me/Full Access

### Terminal compatibility
- A runtime resize now sends `SIGWINCH` to the PTY's foreground process group; Claude Code adapts to window size changes as immediately as Codex does

### Development infrastructure
- XcodeBuildMCP (build/test/launch) + Computer Use (visual acceptance and user flows)
- Deterministic launch: `-ui-testing -reset-state -fixture demo -route -window-width/height -disable-animations` (state in `$TMPDIR/UncoilUITest`)
- Hierarchical accessibility identifiers; 8 UI tests in the `UncoilUI` scheme
- A temporary acceptance workspace created with one click from the command palette; Swift and JavaScript samples, process fixtures for success/failure/long/large output/crash, and permission-classified fake MCP tools
- The guided acceptance flow completed with Computer Use; Claude/Codex sessions, groups and bulk actions, a separate window, restart/reconnect/replay, worktrees, MCP, Browser, Computer Use permission denial and approval, external process termination and recovery, and the session artifact result
- Codex sessions start with the bundled `uncoil-mcp` command and per-session control-plane environment overrides; the global Codex config is left alone
- Debug Bundle export from the command palette; scoped app/runtime logs, agent versions, structurally sanitised configs, MCP/permission/crash/acceptance/system information and a ZIP manifest
- Debug Bundle safety; terminal replay and prompt content are excluded, JSON prompt/history/message fields are structurally erased, and tokens, secrets, CLI secret arguments and home/temp/project/external-disk paths are masked
- A hard-won lesson: AppKit window restoration opened the app with zero windows when a second instance existed → native state restoration is off; the main scene, the frame and the selection are restored deterministically by the app

## Remaining

The current, prioritised work list lives in `TODO.md` at the repo root.

## Known limits

- Persistent runtime v1: if the daemon is unreachable it falls back to an in-process PTY (in which case terminals die with the app); sessions die on reboot either way (the records survive, and Claude/Codex resume brings them back)
- Running from Xcode puts DerivedData on the internal disk (it can be redirected to `.build-cache` in Xcode's settings); launch arguments only take effect in a fresh process
