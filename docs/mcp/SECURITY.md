# MCP control plane — security & threat model

The control plane deliberately gives agents a *bounded* surface. This is the threat
model and the mitigations in place.

## Socket authentication

- `control.sock` lives in the user-private `<AppSupport>/Uncoil/` directory, chmod 0600.
- Every accepted connection passes a `LOCAL_PEERCRED` check: `cred.cr_uid == getuid()`.
  Connections from other users are dropped immediately.
- There is **no network listener** — Unix domain socket only. No auth token is needed
  because the OS enforces the local-user boundary; a token would add nothing.
- Oversized input (>8 MB buffered without a newline) drops the client.

## Path traversal & symlink escape

`uncoil_artifacts` never trusts a caller-supplied `name`:

- `..`, leading `/`, and empty names are rejected outright.
- The resolved path is compared against the **realpath** of the artifact root; a symlink
  inside the root that points outside resolves to a non-contained path and is rejected
  (`INVALID_PATH`). Non-existent leaves resolve their parent to catch symlinked parents.
- Covered by unit tests (`ArtifactPathTests`: dot-dot, absolute, symlink escape).

## Command / argument injection

- `create_child` accepts **no raw shell commands**. Provider, arguments, and the
  grantable capability set come only from a named `SessionPreset`. Worktree targets are
  validated against the project's real `GitService.worktrees` list.
- `worktree` names for `create_worktree` are constrained to `[a-zA-Z0-9._-]{1,64}`.
- `initial_prompt` is capped at 4000 chars and sanitized (control characters except
  tab/newline stripped) before it is fed to the child PTY, so an injected escape
  sequence cannot drive the child terminal.

## Prompt injection from external content

`uncoil_browser` and `uncoil_computer` return page/window content under an
`external_content` key precisely to mark it **untrusted**. Snapshots, page text, and app
UI are data, not instructions. Agents must not follow directives embedded in scraped
content, and the tool descriptions/help say so. The drivers act only on stable element
refs / bound windows — never on implicit "the frontmost thing".

## Privilege escalation between sessions

- The relationship calculator + grants bound every cross-session action. Default grants
  are read-only within a project; control/close/create are opt-in per session.
- Child capabilities are intersected down (preset ∩ caller), never up.
- Non-child control requires an explicit, revocable, **directional** user permission
  (A→B never implies C→B). Grants are re-checked on every call (no caching), so
  revocation is immediate.

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
