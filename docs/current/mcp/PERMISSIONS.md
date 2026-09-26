# MCP control plane — permissions & grants

Three mechanisms gate the control surface, in this order:

0. **Caller identity** — who is asking, established once per request
   (`ControlCallContext`). See below.
1. **Capability grants** — static, per-session. Stored on the `SessionRecord`
   (`capabilities: [String]?`); `nil` means the default set.
2. **User permissions** — dynamic, directional (caller→target), approved in the UI.
   Stored in `<AppSupport>/Uncoil/permissions.json`.

## Caller identity

Every session is launched with `UNCOIL_SESSION_ID` and `UNCOIL_SESSION_TOKEN`. The
token is an HMAC-SHA256 of the session id under a secret only the app holds
(`<AppSupport>/Uncoil/control-secret`, 0600), so it is the same for a session across
app restarts and cannot be derived for another session. `uncoil-mcp` sends both.

| caller sent | verification | may read | may act (any effect) |
|---|---|---|---|
| id + matching token | `verified` | yes | yes |
| id, no token | `unverified` | yes | no — `IDENTITY_UNVERIFIED` (`reason: unverified`) |
| id + wrong token | `mismatched` | no | no — `IDENTITY_UNVERIFIED` (`reason: mismatch`) |
| no id / unknown id | `anonymous` | handler decides (usually `UNKNOWN_SESSION`) | no — `UNKNOWN_SESSION` |

A session launched by a build older than session tokens is `unverified` until it is
restarted. Only `uncoil_system status/version/describe/doctor` and `help` answer
without any caller.

## Effects

Effects are decided in one place, `PolicyEngine.authorize(effect, caller, target,
grants)`, which returns allow, deny, or "the user may allow this"
(`requiresPermission(grantKey)`), and only then is `PermissionService` consulted:

| effect | actions | rule |
|---|---|---|
| `read` | inspect, capabilities, timeline, events | same project: `sessions.read`; other projects: `sessions.read_all` |
| `control` | submit, send_text | `sessions.control_all`, or `sessions.control_children` for a direct child; otherwise user permission `sessions.control`; never self |
| `interrupt`, `resume` | interrupt, resume | as `control` |
| `respond_to_approval` | respond_approval | as `control`, **and** `sessions.approve` — else user permission `sessions.approve` for that target |
| `create_session` | create_session, create_child | `sessions.create_children`; another project also needs `sessions.cross_project` |
| `close` | stop | self, a direct child, `sessions.control_all`; otherwise user permission `sessions.close` |

## Capability grants (PolicyEngine)

Default grants (every session, unless its record overrides `capabilities`):

```
projects.read  worktrees.read  worktrees.create
sessions.read  sessions.read_all  sessions.control_children  sessions.control_all
sessions.create_children  sessions.cross_project  sessions.organize
artifacts.read  artifacts.write
browser.use  browser.persistent_state
```

Opt-in grants, OFF by default and enabled explicitly:

```
computer.inspect           read-only uncoil_computer
computer.background_control mutating uncoil_computer (bound window)
computer.foreground_control bring_to_front (focus steal)
sessions.approve           answer another session's approvals
tasks.delete  tasks.orchestrate  tasks.worktree  tasks.merge
blueprints.write
```

`sessions.approve` is opt-in because answering an approval decides, on the user's
behalf, that a command may run or a file may change. A session holding it for every
session it controls could approve its own work through a child.

A missing grant yields `CAPABILITY_DISABLED`. Grants never widen at runtime except
through the child-capability intersection (which only ever narrows).

## Child capability inheritance

`create_session` / `create_child` compute the new session's grants as
`requested ∩ role ∩ caller's own grants`, where the role is the preset's
`granted_capabilities` (or the default session profile when no preset is named). A role
cannot grant what the caller lacks, and a caller cannot request beyond the role. There
is no raw shell path: a plain terminal is never started through the control plane.

## User permissions (PermissionService)

When policy would deny an action that a human could reasonably authorize — most notably
Computer Use and `bring_to_front` — the handler returns
`PERMISSION_REQUIRED` with `details:{grant_key, target}` instead of a hard denial.

- The agent calls `uncoil_system request_permission {grant_key, target_session_id?}`.
  This creates a **pending**, **directional** record `(from=caller, to=target, key)`.
- The user approves/denies/revokes in **Uncoil → Settings → Permissions**.
- On each subsequent call, `PolicyEngine`/handlers consult `PermissionService.isGranted`
  — no caching. A grant applies only to the exact `(from, to, key)` triple: A→B granted
  never authorizes C→B, nor a different key.

### Lifecycle

- **Pending** requests auto-expire after **10 minutes** (pruned on read).
- **Granted** permissions are durable until **revoked** (removed from the file);
  revocation takes effect on the very next call.
- `permissions.json` is written atomically (write-temp-rename via `AtomicFile`).

### Grant keys used today

| key | lifts |
|---|---|
| `computer.inspect` | inspect the bound application window |
| `computer.background_control` | interact with the bound window without focus stealing |
| `computer.foreground_control` | bring the bound window to the foreground |
| `sessions.control` | submit / send_text / interrupt / resume on a session policy does not cover |
| `sessions.close` | stop an unrelated session |
| `sessions.approve` | answer approvals of one target session |

Explicit per-session capability overrides can still disable any default grant.
