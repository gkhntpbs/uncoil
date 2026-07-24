# MCP control plane — permissions & grants

Two distinct mechanisms gate the control surface:

1. **Capability grants** — static, per-session. Stored on the `SessionRecord`
   (`capabilities: [String]?`); `nil` means the default set.
2. **User permissions** — dynamic, directional (caller→target), approved in the UI.
   Stored in `<AppSupport>/Uncoil/permissions.json`.

## Capability grants (PolicyEngine)

Default grants (every session, unless its record overrides `capabilities`):

```
projects.read  worktrees.read  worktrees.create
sessions.read  sessions.read_all  sessions.control_children  sessions.control_all
sessions.create_children  sessions.cross_project  sessions.organize
artifacts.read  artifacts.write
browser.use  browser.persistent_state
```

Computer Use grants are OFF by default and must be enabled explicitly:

```
computer.inspect           read-only uncoil_computer
computer.background_control mutating uncoil_computer (bound window)
computer.foreground_control bring_to_front (focus steal)
```

A missing grant yields `CAPABILITY_DISABLED`. Grants never widen at runtime except
through the child-capability intersection (which only ever narrows).

## Child capability inheritance

`create_child` computes the child's grants as
`requested ∩ preset.granted_capabilities ∩ caller's own grants`. A preset cannot grant
what the caller lacks, and a caller cannot request beyond the preset. Presets
(`SessionPreset`) are the only capability ceiling for spawned work; there is no raw
shell path.

## User permissions (PermissionService)

When policy would deny an action that a human could reasonably authorize — most notably
Computer Use and `bring_to_front` — the handler returns
`PERMISSION_REQUIRED` with `details:{grant_key, target}` instead of a hard denial.

- The agent calls `uncoil_system request_permission {grant_key, target_session_id?}`.
  This creates a **pending**, **directional** record `(from=caller, to=target, key)`.
- The user approves/denies/revokes in **Uncoil → Ayarlar → İzinler**.
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

Explicit per-session capability overrides can still disable any default grant.
