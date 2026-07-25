# Changelog

All notable changes to Uncoil are recorded here.

## Unreleased

### Added

- Added the Project Tasks system end to end: lossless `TODO.md` discovery and parsing, byte-range patching, document, list, Kanban and session views, task↔session metadata with fingerprint relinking, claims, orchestration, worktree/review/test/merge flows, the `uncoil_tasks` MCP surface, and per-file git state with conflict-aware read-only editing.
- Added task test runs, review verdicts and merge attempts as persisted results, with completion refused on a failing test or a review that asked for changes, and a merge screen that shows the diff, runs, verdict and every remaining blocker before the user approves.
- Added task events to the Attention Center and menu bar, with shortcuts to a project's board, its task sessions and stopping its orchestrator.
- Added Gemini CLI, Cursor and Amp config management through one shared JSON adapter, and surfaced the config transaction plan and one-click rollback in the Agents screen.
- Added per-source-class capabilities for extensions, bundled-extension manifest verification, adoption of externally installed extensions with a diff and backup, and remote MCP health, capability diff and server-reported version.
- Added extension discovery sources, an install preview (owner, licence, commit, scripts, permissions, agents, findings, exact commit, diff) and install guards that refuse a moving reference, a blocked finding, unapproved executables or an invalid structure.
- Added the Bumblebee integration layer: binary resolution order, version and self-test handling with untrusted results on failure, NDJSON scan parsing with `scan_summary` validation, a single-scan lock and per-kind timeouts, both lock files, and a threat catalog versioned apart from the binary with validation, diff and rollback.
- Added Uncoil's own security findings for changed shell commands and unsigned binaries, and made quarantine disable an extension everywhere while deleting nothing.
- Added backup and restore with schema validation, opt-in transcripts, secrets never exported, missing-extension reporting from exact commits, and an all-or-nothing restore.
- Added a release pipeline script with hardened runtime, signature verification and optional notarization/stapling, plus an uninstall plan that removes what Uncoil created and keeps what the user wrote.
- Added a schema registry so every persisted shape declares its version, with older bare-array documents still read and documents from a newer version refused rather than half-read.

### Fixed

- Fixed `GitService` trimming its command output, which ate the leading space of a ` M path` porcelain code and returned the first changed file's path one character short.
- Fixed moving a task into a file whose last line had no newline gluing the moved block onto that line, and the same case in `create_subtask` over MCP.
- Fixed relative paths being computed by string prefix, which collapsed every nested file to its bare name because macOS reports `/private/var` where the URL says `/var`.
- Fixed the backup secret heuristic matching any field whose name contained "key", which silently dropped the permission decisions.
- Fixed the extension registry file being collected three times in a backup because three contents name it.
- Fixed stale Claude Code hook entries pointing at a deleted DerivedData bundle by repairing Uncoil's own entries at launch.

### Added

- Added a one-click acceptance workspace with Swift and JavaScript samples, deterministic process fixtures, and permission-classified fake MCP tools.
- Completed the guided acceptance flow for Claude and Codex sessions, grouping, bulk actions, reconnect and replay, worktrees, Browser, Computer Use permission decisions, process recovery, and session artifact reporting.
- Added command-palette Debug Bundle export with scoped app/runtime logs, agent versions, sanitized configs, MCP diagnostics, permission decisions, crash reports, acceptance results, and system information.
- Added runtime protocol negotiation, heartbeat, crash recovery, sleep/wake reconnect, graceful upgrade drain, bounded replay storage, log rotation, process limits, and real daemon integration tests.
- Added persisted quit behavior with “Keep sessions running” and “Terminate all agents on quit” choices.
- Added explicit main-window recreation, frame autosave, and project/group/session selection restoration.
- Added closed-session history with persisted exit/restart metadata and safe versioned metadata migration.
- Added deterministic Claude and Codex session resume, including Codex rollout metadata discovery.
- Added a session preset editor for provider, arguments, prompt template, permission mode, and capability boundaries.
- Added opt-in transcript retention with 7-day, 30-day, and unlimited policies plus confirmed sensitive transcript cleanup.

### Changed

- Reorganized active product, MCP, and historical reference documentation.
- Made background GitHub Keychain reads non-interactive so development builds no longer repeatedly request the login password.
- Moved transcript writes off the UI thread and shell-quoted preset arguments before launching child sessions.

### Fixed

- Injected the bundled Uncoil MCP server and session-scoped control-plane environment into Codex launches without modifying the user's global Codex configuration.
- Redacted secrets, prompt/history fields, home/temp/project/external-volume paths, and token-bearing CLI arguments from diagnostic exports.
- Moved the foundation plan to `docs/roadmap/FOUNDATION_PLAN.md`.
- Established `TODO.md` as the canonical implementation backlog.
- Replaced the legacy UI-control MCP with Computer Use for Codex.
- Disabled project-scoped tooling for Claude Code.
- Embedded executable helpers under `Contents/Helpers` so macOS accepts their code signatures.
- Added an explicit runtime protocol mismatch alert and hardened daemon single-instance and child cleanup behavior.
- Restored daemon-backed session persistence, reconnect, and terminal replay across app restarts.
- Fixed running-app reopen events producing no visible main window.

### Removed

- Removed the legacy project-level UI-control MCP configuration.
- Removed ignored Finder metadata files from the repository tree.

## 2026-07-24

### Added

- Session groups, bulk session actions, and automatic organization.
- Agent Browser and Computer Use driver settings.
- Provider working-mode settings.
- Foreground process-group terminal resize support.

## 2026-07-23

### Added

- Original clean-room SwiftUI application foundation.
- Persistent terminal runtime daemon.
- Six-tool MCP control plane with orchestration, permissions, artifacts, browser, and computer capabilities.
- Command palette, settings, themes, notifications, popout windows, and split sessions.