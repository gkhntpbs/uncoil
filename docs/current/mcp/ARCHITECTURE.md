# MCP control plane — architecture

Uncoil exposes a bounded control surface to the agents it runs, so a Claude/Codex
session can inspect projects, coordinate child sessions, read artifacts, and (with
grants) drive a browser or native apps — without shell access to the host.

## Layers

```
agent CLI (Claude Code / Codex)
   │  stdio JSON-RPC 2.0 (MCP)
   ▼
uncoil-mcp            (McpHelper/main.swift) — bundled stdio MCP server, one per session
   │  line-delimited JSON over a Unix socket (control.sock)
   ▼
ControlPlaneServer   (App/ControlPlane/ControlPlaneServer.swift) — accept/read on a serial queue
   │  one Task { @MainActor } per request
   ▼
CapabilityRouter     (App/ControlPlane/CapabilityRouter.swift) — validates capability+action against HelpRegistry
   │
   ├─ PolicyEngine        — pure relationship + grant decisions (no I/O)
   ├─ PermissionService   — directional, revocable user permissions (permissions.json)
   ├─ AuditLog            — append-only JSONL of every decision (arg KEYS only)
   └─ handlers            — Projects / Sessions / Artifacts / System / Browser / Computer
                            │
                            └─ Adapters — AgentBrowserAdapter, CuaDriverAdapter (external CLIs)
```

## Socket topology

- **control.sock** — `<AppSupport>/Uncoil/control.sock`, mode 0600, `LOCAL_PEERCRED`
  euid check on every accept. The app is the server; each `uncoil-mcp` process is a
  short-lived client (connect → one request line → one response line → close).
- **runtime.sock** — separate socket owned by `uncoil-runtimed` (PTY ownership). The
  control plane reaches it only through `RuntimeClient` (read_output/peek, send_text,
  interrupt, kill). See the persistent-runtime docs.
- **hook socket** — separate; Claude hooks feed the status machine. Independent of the
  control plane.

## Request/response shape

One `ControlRequest` per `tools/call`: `{version, capability, action, args,
caller_session_id, request_id}`. One `ControlEnvelope` back: `ok` + `data` on success,
or `error {code, message, retryable, details}` on failure; both echo
capability/action/request_id and the resolved project/target ids. Defined once in
`Shared/ControlProtocol.swift` and compiled into BOTH the app and `uncoil-mcp` so the
wire shapes cannot drift.

## Adapter boundaries

`uncoil_browser` and `uncoil_computer` never link a browser or automation framework
into Uncoil. They shell out to optional external CLIs (`agent-browser`, `cua-driver`)
through `ProcessRunner`, and degrade to `BROWSER_UNAVAILABLE` / `COMPUTER_UNAVAILABLE`
when those are absent. All page/app content is returned under an `external_content`
key and is treated as untrusted (see SECURITY.md).

## Trust boundaries

1. **User ↔ host** — the socket's directory perms + euid check keep the surface to the
   local user only. No network listener exists.
2. **Agent ↔ Uncoil** — the agent may call only the six capabilities, only the actions
   in the HelpRegistry, and only within its granted capability set. Safe project,
   session, artifact, worktree, and browser automation is enabled by default;
   Computer Use remains explicitly opt-in (PolicyEngine).
3. **Session ↔ session** — the relationship calculator (self/parent/child/ancestor/
   descendant/sibling/unrelated) plus grants decide read/control/close. Default
   `sessions.control_all` can be narrowed with a per-session capability override.
4. **Agent ↔ external content** — browser/computer snapshots are untrusted input; the
   agent must not follow instructions embedded in them.

## Testability

The whole router + policy + handler stack is socket-free: `CapabilityRouter` is built
from plain stores and is driven directly in unit tests (no IPC). Child launching and
the runtime peek are injected closures/singletons, so orchestration is tested with
fakes.
