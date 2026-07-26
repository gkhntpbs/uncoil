# Uncoil MCP Acceptance Test

This flow has a Claude session started from inside Uncoil exercise the six MCP
tools over the real control plane. The test deletes no existing project data,
creates no worktree, sends no message and uses no persistent browser profile.

## Last verification

On 24 July 2026 the Debug app was run with
`-ui-testing -control-plane -reset-state -fixture demo`. The `uncoil-mcp`
shipped with the app was exercised directly, through the demo Claude session's
id and an isolated `control.sock`. No Claude process was started.

| Area | Result | Evidence |
|---|---|---|
| MCP protocol | PASS | `initialize` protocol `2025-06-18`; `tools/list` returned all six tools. |
| `uncoil_system` | PASS | `help`, `status`, `version`, `capabilities`, `doctor`, `dependencies` all succeeded. The control and hook sockets were ready; the unused runtime daemon was off. |
| `uncoil_projects` | PASS | The demo project, an empty worktree list and the `claude-worker` preset were read. |
| `uncoil_sessions` | PASS | The current demo session, the session list, the child list and an empty report inbox were read. |
| `uncoil_artifacts` | PASS | An empty list came back; a missing artifact was safely refused with `INVALID_PATH`. |
| `uncoil_browser` | PASS | `example.com` was opened in an ephemeral session; snapshot, title, screenshot and the tab list were verified, then the session was closed. |
| `uncoil_computer` | PASS | After per-session Computer Use permission, the permissions, the app list, the Uncoil window, an AX snapshot and a window screenshot were verified. |

40 tool actions returned PASS in total. The first Computer Use attempt produced
the expected `CAPABILITY_DISABLED`; the same read-only flow passed only after
permission was granted to the demo Claude session. No worktree or child session
was created, no message was sent, no persistent browser profile was used and no
driver was installed.

## Preconditions

- Uncoil is running from a current Debug build.
- No second Uncoil process with the same bundle id is running.
- The test session uses Sonnet 5.
- The session is granted these capabilities as they become necessary:
  - `projects.read`
  - `worktrees.read`
  - `sessions.read`
  - `sessions.create_children`
  - `sessions.control_children`
  - `artifacts.read`
  - `artifacts.write`
  - `browser.use`
  - `computer.inspect`
- The Cua Driver is installed, with macOS Accessibility and Screen Recording
  permissions granted.
- If `agent-browser` or the Playwright browser binary it uses is not installed,
  the browser stage records `BROWSER_UNAVAILABLE` as the expected outcome;
  nothing is installed automatically.

## Preparing a run

1. In XcodeBuildMCP's session defaults, confirm the project, the `Uncoil`
   scheme, Debug, arm64 and the `.build-cache/DerivedData` path.
2. Stop every older running Uncoil instance through XcodeBuildMCP.
3. Launch the app under test through XcodeBuildMCP from this full path:
   `.build-cache/DerivedData/Build/Products/Debug/Uncoil.app`
4. In Computer Use calls, target that same full path rather than the app's
   name, so macOS cannot open an older DerivedData copy from the internal disk.
5. Open a new Claude session in Uncoil and confirm the Sonnet 5 selection.
6. Grant the necessary session capabilities to that new session from
   Settings → Permissions.
7. Type the Claude prompt below into the terminal area and send it with a
   physical Return.

## Stages

1. `uncoil_system`
   - `help`, `status`, `version`, `capabilities`, `doctor`, `dependencies`
   - Record the control socket, runtime daemon, git, data directory and
     dependency results.
2. `uncoil_projects`
   - `help`, `current`, `list`, `inspect`, `list_worktrees`, `list_presets`
   - `inspect_preset` for the first preset.
   - Do not call `create_worktree`.
3. `uncoil_sessions`
   - `help`, `current`, `list`, `inspect`, `list_children`, `read_reports`
   - With the capability, create a single child from the `claude-worker` preset.
   - Tell the child only to call `uncoil_system status` and report the result
     with `report_to_parent`.
   - Verify `inspect_child`, `wait_for_children`, `summarize_children` and
     `read_reports`.
   - If the child is still running, close it with `stop`.
4. `uncoil_artifacts`
   - `help`, `list`
   - If the list holds a file: `inspect`, `resolve_path`, and `read_text` if it
     is text.
   - Call `inspect` with a name that does not exist, to verify the safe error
     contract.
5. `uncoil_browser`
   - `help`, `status`
   - If the engine is installed, start an ephemeral session only; open
     `https://example.com`, then `snapshot`, `get title`, `screenshot`,
     `list_tabs`, then `stop`.
   - If the CLI or the Playwright browser binary is not installed, record
     `BROWSER_UNAVAILABLE` as the expected outcome and install nothing.
6. `uncoil_computer`
   - Without repeating already-verified control actions: `help`, `status`,
     `permissions`, `list_apps`.
   - Bind the Uncoil window with `inspect_window`, then take a `snapshot` and a
     `screenshot`.
   - Do not click, type or call `bring_to_front` in this acceptance test.

## Result format

Claude produces a single table:

| Tool | Action | Result | Evidence |
|---|---|---|---|
| `uncoil_system` | `status` | PASS/FAIL/BLOCKED | The key fields returned, or the error code |

At the end it lists the PASS, FAIL and BLOCKED totals; the expected missing
dependencies; the permissions granted; the child session id created; and the
artifact paths produced. A failing stage does not stop the others.

## Claude prompt

```text
Run the Uncoil MCP acceptance test. Use only the uncoil_system, uncoil_projects, uncoil_sessions, uncoil_artifacts, uncoil_browser and uncoil_computer tools Uncoil provides. Call help on each tool first and follow the current contract it returns.

In order:
1) uncoil_system: status, version, capabilities, doctor, dependencies.
2) uncoil_projects: current, list, inspect, list_worktrees, list_presets, and inspect_preset for the first preset. Do not call create_worktree.
3) uncoil_sessions: current, list, inspect, list_children, read_reports. If the sessions.create_children and sessions.control_children capabilities are present, create a single child from claude-worker that only calls uncoil_system status and then report_to_parent; verify it with inspect_child, wait_for_children, summarize_children and read_reports; if the child is still running, close it with stop.
4) uncoil_artifacts: list; if a file is there, inspect, resolve_path and read_text if it is text; also inspect a name that does not exist, to verify the safe error code.
5) uncoil_browser: status. If the CLI and the Playwright browser binary are ready, start an ephemeral_session, open only https://example.com, then call snapshot, get title, screenshot, list_tabs and stop. If either is not installed, record BROWSER_UNAVAILABLE as an expected BLOCKED; install nothing.
6) uncoil_computer: status, permissions, list_apps; bind the com.gkhntpbs.uncoil window with inspect_window, then take a snapshot and a screenshot. Do not click, type or call bring_to_front.

If a permission is missing, write plainly which grant_key is needed and wait. When it is granted, continue from where you stopped. One failure must not stop the other stages. Do not create a worktree, do not change or delete existing files, do not send messages, do not use a persistent browser profile, and do not run a remote install.

Finish with a single table with the columns Tool | Action | Result | Evidence, plus the PASS/FAIL/BLOCKED totals. Keep the error codes verbatim; list the child session id and the artifact paths.
```
