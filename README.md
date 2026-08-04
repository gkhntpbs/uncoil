# Uncoil

A native macOS control center for coordinating AI coding agents — Claude Code and
Codex — across projects, worktrees and accounts.

Agents are good at working in a terminal and bad at being many terminals. Uncoil
gives each agent a real PTY that survives the app closing, tells you which agent
is thinking and which one is waiting for you, and puts every project, session and
worktree in one window instead of fifteen tabs.

Free, and free software. **Status: `0.1.0`, the first beta.** Requires macOS 14 or
later, Apple silicon.

## What it does

- **Sessions that do not die.** A separate daemon (`uncoil-runtimed`) owns the
  PTYs, so agents keep working when the app is closed, crashes, or is updated.
  Closed sessions resume rather than restart — Claude Code comes back with
  `--resume`, keeping its history.
- **Honest status.** Ready · Thinking · Running a tool · Waiting for permission ·
  Waiting for a reply, read from Claude Code's own hooks rather than guessed from
  terminal output.
- **Projects, worktrees and multiple windows.** Git worktrees are first-class, a
  session is shown in one window at a time and the others say where it is, and
  each window keeps its own selection, layout and frame.
- **Accounts.** Each profile gets an isolated `CLAUDE_CONFIG_DIR` / `CODEX_HOME`,
  so more than one account can be signed in at once without them fighting.
- **An MCP control plane.** Uncoil exposes a bounded, permissioned MCP surface to
  the agents it runs — projects, sessions, artifacts, tasks, run, system, browser
  and computer. Child sessions can only be created from named presets with
  capabilities intersected against the caller, never escalated. See
  [`docs/current/mcp/`](docs/current/mcp/).
- **A command palette**, themes, notifications, popout windows and split sessions.

## Install

Download the latest notarized `.dmg` from the
[Releases page](https://github.com/gkhntpbs/uncoil/releases), open it, and drag
Uncoil to Applications. The app checks for updates on its own after that.

## Build from source

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `Uncoil.xcodeproj` is generated and not checked in, so
generate it first:

```bash
xcodegen generate
xcodebuild -project Uncoil.xcodeproj -scheme Uncoil -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

Run the tests with `test` in place of `build`. The only dependency is
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), fetched by SPM.

## Layout

| Path | What lives there |
|---|---|
| `App/` | The app. `Core/` models and stores, `Terminal/` the SwiftTerm host, `UI/` views, `UI/AppKit/` the `NSOutlineView`-backed lists |
| `RuntimeHelper/` | `uncoil-runtimed`, the daemon that owns the PTYs |
| `McpHelper/` | `uncoil-mcp`, the bundled MCP stdio server |
| `HookHelper/`, `ExtensionHelper/` | The Claude Code hook bridge and the extension host |
| `Shared/` | Wire protocols compiled into both the app and the helpers |
| `docs/current/` | Product status, release process, MCP documentation |
| `docs/roadmap/` | Where this is going |

## Contributing

Issues and pull requests are welcome. Two rules matter more than style:

1. **Clean room.** Uncoil is an original codebase. Never copy code from a GPL
   project into it — the audit under `docs/history/` is documentation of
   a *design*, not a source to lift from.
2. **No new dependencies** unless there is no reasonable alternative, and then
   only MIT, BSD or Apache-2.0. Never GPL.

Run the test suite before opening a pull request.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for third-party components.
