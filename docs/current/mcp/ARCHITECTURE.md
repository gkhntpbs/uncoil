# MCP control plane — architecture

Uncoil exposes a bounded control surface to the agents it runs, so a Claude/Codex
session can inspect projects, create and coordinate other sessions, follow their work
as structured events, read artifacts, and (with grants) drive a browser or native
apps — without shell access to the host.

The control plane is thin by design. It decides *who* is calling and *whether* they
may; what a session can do, and how a prompt or an interrupt reaches its agent, belong
to the AgentSession layer underneath it.

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
   ├─ ControlCallContext  — who is calling: session, provider, project, account, grants, verification
   ├─ identity gate       — refuses a mismatched token; effects need a verified caller
   ├─ IdempotencyLedger   — an effect with an idempotency_key runs once
   ├─ PolicyEngine        — pure relationship + grant decisions, `authorize(effect, …)`
   ├─ PermissionService   — directional, revocable user permissions (permissions.json)
   ├─ AuditLog            — append-only JSONL of every decision (arg KEYS only)
   └─ handlers            — Sessions / Agents / Projects / Artifacts / Tasks / Run / System / Browser / Computer
          │                 │
          │                 └─ Adapters — AgentBrowserAdapter, CuaDriverAdapter (external CLIs)
          ▼
AgentSession layer   (App/AgentSession/) — the only way into and out of a session
   ├─ AgentSessionControl — submit / interrupt / respond(toApproval:) / sendRaw + `capabilities`, `isReady`
   ├─ AgentEventHub       — per-session AgentTimeline + the last 2000 AgentEventRecords
   └─ provider runtimes   — CodexAppServerSession, ClaudeStreamSession (structured), PTYAgentSessionControl (terminal)
```

The session handlers reach a session only through two seams on the router:
`sessionControl(record)` (the running session's `AgentSessionControl`, or nil) and
`eventHub`. They never touch `TerminalRegistry`, a PTY, or a provider protocol, and they
never ask which provider a session is: the Codex app server and a terminal-only agent
answer the same calls — and so does a structured Claude session
(`docs/current/claude/STREAM_JSON.md`) — and `SessionCapabilityReport` — built from the control's
capabilities, the provider's `AgentDescriptor`, and whether a timeline exists — says
what differs. A new provider joins by implementing `AgentSessionControl` and publishing
`AgentEvent`s; the control plane needs no change.

## Socket topology

- **control.sock** — `<AppSupport>/Uncoil/control.sock`, mode 0600, `LOCAL_PEERCRED`
  euid check on every accept. The app is the server; each `uncoil-mcp` process is a
  short-lived client (connect → one request line → one response line → close).
- **runtime.sock** — separate socket owned by `uncoil-runtimed` (PTY ownership). The
  control plane reaches it only through `RuntimeClient` (read_output/peek, send_text,
  interrupt, kill). See the persistent-runtime docs.
- **hook socket** — separate; Claude hooks feed the status machine. Independent of the
  control plane.

## Registration

Every provider points at the same entry: the bundled `uncoil-mcp` binary, with the same
four environment variables (`UNCOIL_SESSION_ID`, `UNCOIL_SESSION_TOKEN`,
`UNCOIL_PROJECT_ID`, `UNCOIL_CONTROL_SOCKET`) built once by
`ControlProtocol.mcpEnvironment(for:)`. Provider-specific code only decides how those
arrive — Claude's `--mcp-config` file, Codex's `-c mcp_servers.uncoil.*` overrides or
app-server config, OpenCode's `OPENCODE_CONFIG_CONTENT` — and the server discovers the
caller at runtime from them.

## Request/response shape

One `ControlRequest` per `tools/call`: `{version, capability, action, args,
caller_session_id, session_token, client, request_id}`. One `ControlEnvelope` back: `ok` + `data` on success,
or `error {code, message, retryable, details}` on failure; both echo
capability/action/request_id and the resolved project/target ids. Defined once in
`Shared/ControlProtocol.swift` and compiled into BOTH the app and `uncoil-mcp` so the
wire shapes cannot drift.

## Request execution

- **Concurrency.** `uncoil-mcp` answers each `tools/call` on its own thread, so its
  stdin loop keeps reading while a long call waits; stdout writes are serialized.
- **Timeouts.** The MCP server waits `ControlProtocol.callTimeout(args:)` — the action's
  own `timeout_s`/`wait_s` plus 15 s, at least 30 s, at most 330 s — instead of a fixed
  30 s that used to cut every longer wait short.
- **Cancellation.** `notifications/cancelled` closes that call's socket and suppresses
  its response. `ControlPlaneServer` cancels every in-flight request of a connection that
  hangs up, and every wait loop checks `Task.isCancelled` and returns `CANCELLED`.
- **Retries.** An effect carrying `idempotency_key` runs once per (caller, action, key);
  a retry while the first is running waits for it. Retryable failures are not
  remembered. The ledger is in memory: it covers a client retrying, not an app restart.
- **Stale sessions.** An effect on a session with no running control is
  `SESSION_NOT_RUNNING` (with `details.next`: `resume` or `create_session`); an agent
  that is running but not ready (a structured session mid-handshake, a crashed
  provider) is `PROVIDER_UNAVAILABLE`, retryable. An `events` wait ends as soon as its
  session stops.

## Protocol evolution

- `ControlProtocol.version` (now 2) is the request shape; the server accepts
  `minimumVersion` (1) upward and refuses a newer one with `UNSUPPORTED_VERSION`.
  Changes are additive: fields are added, never renamed or repurposed, and requests
  decode leniently (only `capability` and `action` are required).
- Error codes, action names, effect names, session operation names and event `type`s
  are stable strings. `uncoil_system describe` reports all of them at runtime, read
  from the same tables the router enforces.
- `Tests/McpContractTests.swift` states the contract as behaviour — unknown session,
  unsupported capability, invalid action, cancelled request, stale session, permission
  denied, provider unavailable, structured submit, timeline and event pagination,
  identity and idempotency — so a refactor that changes what a client sees fails there.

## Adapter boundaries

`uncoil_browser` and `uncoil_computer` never link a browser or automation framework
into Uncoil. They shell out to optional external CLIs (`agent-browser`, `cua-driver`)
through `ProcessRunner`, and degrade to `BROWSER_UNAVAILABLE` / `COMPUTER_UNAVAILABLE`
when those are absent. All page/app content is returned under an `external_content`
key and is treated as untrusted (see SECURITY.md).

## Trust boundaries

1. **User ↔ host** — the socket's directory perms + euid check keep the surface to the
   local user only. No network listener exists.
2. **Agent ↔ Uncoil** — the agent may call only the registered capabilities, only the actions
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
from plain stores and is driven directly in unit tests (no IPC). Session control, the
event hub, child launching, provider detection and launch options are injected, so
orchestration is tested with `FakeAgentSessionControl` and a private `AgentEventHub`.
One test (`ControlPlaneCancellationTests`) goes through the real socket to prove that a
client hanging up ends the work it asked for.
