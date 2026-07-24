# Changelog

All notable changes to Uncoil are recorded here.

## Unreleased

### Changed

- Reorganized active product, MCP, and historical reference documentation.
- Moved the foundation plan to `docs/roadmap/FOUNDATION_PLAN.md`.
- Established `TODO.md` as the canonical implementation backlog.
- Replaced the legacy UI-control MCP with Computer Use for Codex.
- Disabled project-scoped tooling for Claude Code.
- Embedded executable helpers under `Contents/Helpers` so macOS accepts their code signatures.

### Fixed

- Restored daemon-backed session persistence, reconnect, and terminal replay across app restarts.

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