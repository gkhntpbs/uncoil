# Codex app-server integration

> **Status: opt-in.** Codex sessions run the Codex CLI in a PTY by default —
> the way Claude sessions run theirs. The app-server path speaks JSON, which
> means Uncoil has to provide the prompt, the history and the line editing that
> the CLI's own TUI would otherwise give; without them a session opened onto a
> bare cursor. The protocol client was not deleted: structured approvals and
> turn state are built on it and its tests still run. Turn it on with the
> `-codex-app-server` argument (`LaunchConfig.codexAppServerEnabled`).

Uncoil's `codex app-server` protocol integration comes into play with that
argument. The interactive Codex PTY path is the default; it is kept as a
compatibility and runtime fallback even when the app-server is on.

## Protocol mapping

- Verified Codex CLI: `codex-cli 0.145.0`
- Official JSON schema generation: `codex app-server generate-json-schema`
- Uncoil's schema mapping: `CodexAppServerCompatibility.schemaVersion`
- Supported range: `0.145.x`
- Transport: a WebSocket over a per-session, user-private Unix socket
- Message format: one JSON-RPC-like message per WebSocket text frame; the
  `jsonrpc` field is unused
- Handshake: an `initialize` request, then an `initialized` notification

An unsupported version, a failed handshake, a process start error or a broken
socket produces a plain compatibility message and moves that session onto the
existing PTY path. If the provider or preset carries extra CLI arguments that
cannot be translated to the structured protocol, the session starts on the PTY
directly.

## Lifecycle

Every Codex session uses this directory:

```text
<Uncoil data>/cas/<session-prefix>/
├── s.sock
├── server.pid
└── server.log
```

The app-server runs in a `0700` directory holding a `0600` socket. Under the
“Keep sessions running” preference the server lives on even after Uncoil closes
the WebSocket connection. When the app reopens it connects to the same socket
and calls `thread/resume` with the persistent thread id. If the session is
closed explicitly, or “Terminate all agents on quit” is selected, the server is
terminated after its PID is verified.

A stale socket connection is repaired once, with a clean start. A second failure
triggers the fallback; no endless restart loop is created.

## Thread and turn flow

A new session:

1. `account/read`
2. `thread/start`
3. Store the returned `thread.id` atomically in `SessionRecord.providerSessionID`
4. `turn/start` on user input

A continuing session:

1. `account/read`
2. `thread/resume`
3. Fetch the last 50 turns in full item form with `initialTurnsPage`
4. Render the structured history onto the terminal surface

Ctrl-C calls `turn/interrupt` when there is an active turn id.

## Domain event mapping

| App-server event | What Uncoil does |
|---|---|
| `thread/status/changed` | Maps the session state to running, idle or error |
| `turn/started` | `thinking` |
| `turn/completed` | `completed`; error detail for a failed turn |
| `item/agentMessage/delta` | Streams the agent's text as it renders |
| `item/commandExecution/outputDelta` | Streams command output as it renders |
| `item/started` | Shows reasoning, command, file change, MCP and tool state structurally |
| `item/completed` | Completes the final item result; streamed text is not repeated |
| `account/updated` | Refreshes the authentication metadata |

Terminal text is never parsed to infer a status or a tool type. The terminal is
used only as the visible output of structured events, and for user input.

## Approvals

Supported server requests:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`

The session screen shows the request's title, its reason and the decisions the
server reports. Command and file decisions are answered with `accept`,
`acceptForSession` or `decline`. A permissions request sends back only the
requested permission profile; a denial uses an empty one. While an approval is
pending the session is in the `waitingForPermission` state.

## Authentication

Uncoil does not ask for a token refresh in its `account/read` call and keeps
only the account metadata. No raw token enters the app's model or its logs.

- `authenticated` when an account exists
- `required` when `requiresOpenaiAuth` is true and there is no account
- `error` on a protocol failure

The need to sign in appears on the session screen. Signing in happens in Codex's
own official login flow.

## Fallback boundary

The PTY fallback is used when:

- The Codex binary cannot be found
- The Codex version is outside the recorded schema range
- The Unix socket or the WebSocket handshake fails
- Initialize, thread start or resume fails
- The session preset or the provider setting carries an untranslatable extra CLI
  argument
- A UI test does not explicitly opt into the app-server fixture

The fallback changes neither the existing runtime daemon nor the in-process
terminal paths.

## Verification

Deterministic test coverage:

- Response, notification and server-request envelope decoding
- JSON request/response framing
- Codex version/schema compatibility
- Structured history and resume-page rendering
- Command and MCP tool rendering
- Consecutive, fragmented and extended-length WebSocket frame decoding
- The approval panel's three decision paths
- The PTY fallback

Manual acceptance:

```text
-ui-testing -reset-state -fixture demo -route project
-window-width 1100 -window-height 720 -disable-animations
-runtime -codex-app-server
```

With Computer Use the AX tree is re-read after every state change. Because
SwiftTerm exposes no AX content, the terminal's visual output is verified with a
window screenshot and the session state through `session.container`.
