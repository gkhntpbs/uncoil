# MCP control plane — artifacts & session data

Everything the control plane writes lives under the per-session tree in Application
Support, so ownership is unambiguous and cleanup is per-session.

## Directory layout

```
<AppSupport>/Uncoil/
├── projects.json                  # ProjectStore (atomic)
├── sessions.json                  # ProjectStore (atomic)
├── settings.json                  # SettingsStore, incl. session presets (atomic)
├── permissions.json               # PermissionService (atomic)
├── control.sock                   # control-plane listener (0600)
├── runtime.sock                   # uncoil-runtimed (0600)
├── audit/<yyyy-mm-dd>.jsonl        # AuditLog, append-only
├── mcp/<session-id>.json          # per-session --mcp-config for Claude Code
└── projects/<project-id>/sessions/<session-id>/artifacts/
    ├── artifacts.json             # registered artifact metadata (atomic)
    ├── reports/inbox.jsonl        # child→parent reports (append-only)
    ├── browser/screenshots/*.png  # uncoil_browser screenshots
    ├── browser/states/*.json      # persisted browser state
    └── computer/screenshots/*.png # uncoil_computer screenshots
```

## Ownership & access

- The **artifact root** is `SessionRecord.artifactRoot(dataDirectory:)` =
  `projects/<pid>/sessions/<sid>/artifacts`. A session always owns its own root.
- Reading **another** session's artifacts requires the `artifacts.read` grant AND that
  the target be in the same project. Cross-project artifact access is not offered.
- Path resolution is symlink-safe: `containedPath` rejects `..`, absolute paths, and
  any name whose realpath escapes the root (see SECURITY.md). `read_text` is capped at
  256 KB.

## Reports inbox

`report_to_parent` appends one JSON line `{ts, from_session, message (≤8 KB), data?}`
to the **parent's** `reports/inbox.jsonl`. The parent reads it with `read_reports`
(optionally clearing) and sees the pending count as `pending_reports` in its own
`sessions.inspect` payload. This is the one-way child→parent channel; there is no
parent→child message store (parents use `send_text` on direct children).

## Durability

`projects.json`, `sessions.json`, `settings.json`, `permissions.json`, and
`artifacts.json` are all written with write-temp-rename, so a crash mid-write leaves
either the previous or the new complete file — never a torn one. The append-only logs
(`audit`, `inbox.jsonl`) use `FileHandle` seek-to-end appends.
