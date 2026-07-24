# MCP control plane — troubleshooting

## First stop: doctor

From an agent session: `uncoil_system {"action":"doctor"}`. It returns a check list
`{name, ok, detail, remedy}` for:

| check | ok means | if not ok |
|---|---|---|
| `control_socket` | `control.sock` present | restart Uncoil to recreate the socket |
| `runtime_daemon` | `uncoil-runtimed` reachable | open a terminal session to spawn it |
| `git` | `/usr/bin/git` present | install the Xcode command line tools |
| `data_dir` | App Support writable | check Application Support permissions |
| `hook_server` | hook socket running | optional; install from Settings → Hooks |
| `agent_browser` | agent-browser installed | optional; install only with user approval |
| `cua_driver` | cua-driver installed | optional; install only with user approval |

`uncoil_system {"action":"dependencies"}` reports the external-driver install state and
versions in isolation.

## Common failures

**`CONTROL_PLANE_UNAVAILABLE` from the MCP tool.**
The `uncoil-mcp` process could not reach the app socket. Check that Uncoil is running,
that `UNCOIL_CONTROL_SOCKET` is set in the session env, and that the path exists. Under
UI-test launches the control plane is gated off unless `-control-plane` is passed.

**`SESSION_NOT_RUNNING` on `read_output`.**
The runtime daemon has no live PTY for that session (e.g. it exited, or the app fell
back to in-process PTYs). Re-open/select the session; the record persists but the PTY
does not survive a reboot.

**`CAPABILITY_DISABLED`.**
The session lacks the opt-in grant. Grants live on the `SessionRecord.capabilities`;
a session must be created with the grant (children get theirs from the preset ∩ caller
intersection). See PERMISSIONS.md.

**`PERMISSION_REQUIRED`.**
A human must approve. Call `uncoil_system request_permission {grant_key,
target_session_id}` (the denial's `details` carry both), then have the user approve in
**Ayarlar → İzinler**. Retry after approval.

**`create_child` → `INVALID_ARGUMENT: unknown preset_id`.**
List valid presets with `uncoil_projects {"action":"list_presets"}`. Built-ins are
`claude-worker` and `codex-reviewer`.

**`create_child` → `PERMISSION_DENIED: cross-project`.**
The target `project_id` differs from the caller's and the caller lacks
`sessions.cross_project`.

**Child spawned but no initial prompt appeared.**
The prompt is sent after the agent reports ready (first hook) or a 3s fallback. If the
child never started (daemon unreachable), the prompt is dropped; check `doctor`.

**A worktree target is rejected.**
`worktree_path` must exactly match a path from
`uncoil_projects {"action":"list_worktrees"}` for that project.

## Where to look

- Decisions: `<AppSupport>/Uncoil/audit/<yyyy-mm-dd>.jsonl` (arg keys, not values).
- Pending/granted permissions: `<AppSupport>/Uncoil/permissions.json` and the İzinler
  pane.
- Per-session artifacts and report inbox: `projects/<pid>/sessions/<sid>/artifacts/`.

## Running / testing the server

The `uncoil-mcp` binary ships inside `Uncoil.app/Contents/Resources`. It is exercised
end-to-end through the app; the control-plane logic itself is covered by the unit suite
(`UncoilTests`, socket-free). Build/test:

```
xcodegen generate
xcodebuild -project Uncoil.xcodeproj -scheme Uncoil -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-cache/DerivedData test
```
