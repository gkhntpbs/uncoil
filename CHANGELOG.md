# Changelog

All notable changes to Uncoil are recorded here.

## Unreleased

### Added

- Added a one-click acceptance workspace with Swift and JavaScript samples, deterministic process fixtures, and permission-classified fake MCP tools.
- Completed the guided acceptance flow for Claude and Codex sessions, grouping, bulk actions, reconnect and replay, worktrees, Browser, Computer Use permission decisions, process recovery, and session artifact reporting.
- Added command-palette Debug Bundle export with scoped app/runtime logs, agent versions, sanitized configs, MCP diagnostics, permission decisions, crash reports, acceptance results, and system information.
- Added runtime protocol negotiation, heartbeat, crash recovery, sleep/wake reconnect, graceful upgrade drain, bounded replay storage, log rotation, process limits, and real daemon integration tests.
- Added persisted quit behavior with “Keep sessions running” and “Terminate all agents on quit” choices.
- Added explicit main-window recreation, frame autosave, and project/group/session selection restoration.

### Changed

- Reorganized active product, MCP, and historical reference documentation.
- Made background GitHub Keychain reads non-interactive so development builds no longer repeatedly request the login password.

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