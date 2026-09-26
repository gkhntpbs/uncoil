# MCP control plane — security & threat model

The control plane deliberately gives agents a *bounded* surface. This is the threat
model and the mitigations in place.

## Socket authentication

- `control.sock` lives in the user-private `<AppSupport>/Uncoil/` directory, chmod 0600.
- Every accepted connection passes a `LOCAL_PEERCRED` check: `cred.cr_uid == getuid()`.
  Connections from other users are dropped immediately.
- There is **no network listener** — Unix domain socket only. The OS enforces the
  local-user boundary for the socket itself.

## Caller identity

The socket proves *which user* is calling, not *which session*. A session id alone is
a claim any process of the same user could make, so each session is launched with a
per-session token (HMAC-SHA256 of its id under the app's secret in
`<AppSupport>/Uncoil/control-secret`, 0600). A call only acts as a session when its
token matches: a wrong token is refused outright, and a missing one may read but not
cause effects. See PERMISSIONS.md → Caller identity. Tokens are compared in constant
time and never logged; the audit log records only the verification outcome.
- Oversized input (>8 MB buffered without a newline) drops the client.

## Path traversal & symlink escape

`uncoil_artifacts` never trusts a caller-supplied `name`:

- `..`, leading `/`, and empty names are rejected outright.
- The resolved path is compared against the **realpath** of the artifact root; a symlink
  inside the root that points outside resolves to a non-contained path and is rejected
  (`INVALID_PATH`). Non-existent leaves resolve their parent to catch symlinked parents.
- Covered by unit tests (`ArtifactPathTests`: dot-dot, absolute, symlink escape).

## Command / argument injection

- `create_session` / `create_child` accept **no raw shell commands** and never start a
  plain terminal. Extra arguments come only from a named `SessionPreset`; `model` and
  `effort` must be single tokens (no whitespace or control characters), `effort` and
  `working_mode` must be values the installed CLI offers, and `account_id` must be one of
  that provider's accounts. Worktree targets are validated against the project's real
  worktree list.
- `worktree` names for `create_worktree` are constrained to `[a-zA-Z0-9._-]{1,64}`.
- `initial_prompt` and `submit` input are capped at 16000 chars and sanitized (C0 and
  C1 control characters and DEL stripped, except tab/newline) before they reach a
  session, so an injected escape sequence — `ESC [` or its one-byte form `0x9B` — cannot
  drive a terminal.

## Prompt injection from external content

`uncoil_browser` and `uncoil_computer` return page/window content under an
`external_content` key precisely to mark it **untrusted**. Snapshots, page text, and app
UI are data, not instructions. Agents must not follow directives embedded in scraped
content, and the tool descriptions/help say so. The drivers act only on stable element
refs / bound windows — never on implicit "the frontmost thing".

## Privilege escalation between sessions

- The relationship calculator + grants bound every cross-session action. Project,
  session, artifact, worktree, and browser automation are enabled by default; explicit
  per-session overrides can narrow them.
- Child capabilities are intersected down (role ∩ caller), never up.
- Answering another session's approval needs the opt-in `sessions.approve` grant (or a
  per-target user permission), so an agent cannot approve its own work through a child.
- Every effect requires a verified caller (see Caller identity).
- Computer Use is always opt-in. Its inspect, background-control, and foreground-control
  grants are re-checked on every call, so revocation is immediate.

## Audit

Every request — allow or deny — is appended to `audit/<day>.jsonl` with the decision,
error code, caller/target, capability/action, and argument **keys**. Argument *values*
are never logged (they may hold secrets). This gives an after-the-fact trail without
becoming a secrets sink.

## Foreground / focus stealing

`uncoil_computer bring_to_front` is the only action that can steal user focus. It
requires `computer.foreground_control`, returns a warning, and is audited. All other
computer actions operate on the per-session bound window in the background.

## Supply chain / external installers

`agent-browser` and `cua-driver` are optional external CLIs. Uncoil never installs them
silently. Any install of these drivers, or any remote install script, MUST be run only
with explicit user approval.
