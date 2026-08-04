# Uncoil release pipeline

`scripts/release.sh` runs the build, signing, packaging and — with credentials —
notarization and stapling. This document is the gate around it: what must be
true before it runs, and the distribution decisions behind it.

## Build inputs

- Generated project source: `project.yml`
- Scheme: `Uncoil`
- Configuration: `Release`
- Destination: `platform=macOS,arch=arm64`
- DerivedData: `.build-cache/DerivedData`
- Development team: `K3TKWWVEB9`
- Bundle identifier: `com.gokhantopbas.uncoil`

## Validation

1. Confirm the working tree is clean and the release commit is tagged.
2. Regenerate `Uncoil.xcodeproj` from `project.yml`.
3. Run the full `Uncoil` unit suite.
4. Run the `UncoilUI` smoke suite.
5. Run the MCP acceptance flow in `docs/current/mcp/ACCEPTANCE_TEST_FLOW.md`.
6. Launch the Release app and verify its main project, session, settings, light icon, and dark icon states with Computer Use.
7. Confirm `uncoil-runtimed`, `uncoil-hook`, and `uncoil-mcp` exist under `Uncoil.app/Contents/Resources`.
8. Verify the final signature and bundle identifier.

## Release build

```bash
xcodegen generate
xcodebuild -project Uncoil.xcodeproj -scheme Uncoil -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build-cache/DerivedData build
```

## Distribution status

Notarization, Developer ID signing, DMG packaging, update feeds, GitHub Releases, and CI workflows are not implemented. Do not publish a build until those steps have explicit credentials, automation, rollback instructions, and a successful clean-machine installation test.

The files under `docs/history/` describe a historical third-party release system. They are not commands or configuration for Uncoil.

---

This document records Uncoil's distribution decisions and the reasons behind
them. The reasoning is kept here so that "why is it like this?" still has an
answer six months from now.

## Pipeline

`scripts/release.sh`:

1. `xcodegen generate` — the project file is produced.
2. Debug tests — nothing continues until they are green.
3. `MARKETING_VERSION` is read and `CHANGELOG.md` is searched for a section
   covering that version. There is no release without release notes.
4. Release archive (hardened runtime **on**; off in Debug, so that a local
   build does not send the debugger and the helper processes through an
   entitlement round-trip).
5. Developer ID export, then signature verification. If the signature carries
   no `runtime` flag the script stops: notarization would reject that build.
6. The helper binaries (`uncoil-mcp`, `uncoil-hook`, `uncoil-extension`,
   `uncoil-runtimed`) are each verified.
7. zip via `ditto`, plus a SHA-256.
8. With `--notarize`, `notarytool submit --wait` and `stapler staple`.

Notarization needs credentials (`xcrun notarytool store-credentials`, then
`NOTARY_PROFILE`). Without them the script does not guess; it stops.

Signing team: `K3TKWWVEB9` (Apple Development: Alparslan Topbas), bundle id
`com.gokhantopbas.uncoil`.

## The update-mechanism decision

**Decision: no Sparkle; GitHub Releases and a manual download.**

Why:

- Uncoil's dependency policy is "zero new dependencies" (`CLAUDE.md`). Sparkle
  may be MIT, but it brings a signed appcast, EdDSA key management and an
  updater process of its own along with it.
- Uncoil already updates the agent CLIs and the extensions. A mechanism that
  also updated the app itself, quietly, would contradict the rule that nothing
  happens without the user's approval.
- Checking the version is cheap: `uncoil_system` already reports it, a new
  release can be read from GitHub Releases, and the download happens when the
  user clicks.

The decision closes no door: if the need becomes clear, a signed appcast can be
added.

## App update rollback policy

Uncoil does not downgrade itself. The policy:

- Every release zip and its SHA-256 stays on GitHub Releases; going back means
  "download the previous zip and replace the one in `/Applications`".
- The app's data is schema-versioned (`UncoilSchema`). A new version carries an
  old schema it can read forward; **an old version refuses a new schema** rather
  than half-reading it. So a downgrade produces a plain "this file is newer than
  this build" message, not data loss.
- If you are planning a downgrade, take a backup with `BackupService` first:
  restoring validates the schema and tells you which extension can be
  reinstalled from which commit.

## Updating the runtime daemon

`uncoil-runtimed` ships inside the app bundle; it is not installed separately.

- The protocol version is compared between the app and the daemon during the
  handshake (`RuntimeProtocol.version` / `minor`). On a mismatch the app keeps
  its sessions on its own in-process PTY and reports the mismatch in the
  Attention Center.
- When the app is updated the old daemon may keep running: the new app sees the
  mismatch and tells the user to restart the daemon. Because the daemon carries
  running agents it is **never killed automatically**; that is the user's call.
- The daemon stays single-instance through `flock`; two versions cannot share
  one socket.

## The SMAppService decision

**Decision: not needed.**

- The daemon is started by the app when it is needed and lives on after the app
  closes; agents running while the app is closed is what requires that.
- `SMAppService` (a login item) would start the daemon when the user logs in.
  That is not Uncoil's need: with no agent, a running daemon is pointless too.
- Adding a login item also asks the user for a separate approval and a system
  settings window — wrong to ask for when there is no work to run.

This decision is reversible too: if scheduled Bumblebee scans are to run while
the app is closed, `SMAppService` gets reconsidered.

## Uninstall

`UninstallService` **lists** what will be deleted first. The rule: what Uncoil
created is deleted, what the user wrote stays.

Deleted:

- Uncoil's data in `~/Library/Application Support/Uncoil` (projects, sessions,
  settings, presets, permission decisions, the audit log, transcripts, TODO
  backups).
- The extension store's mirror, revision, lock and scan directories.
- The symlinks **Uncoil installed** in the agents' skill directories.
- `~/.agents/.skill-lock.json` (a file Uncoil produced).

Not deleted:

- Skill folders the user wrote by hand, and anyone else's symlinks.
- Agent config files (`~/.claude.json`, `~/.codex/config.toml`,
  `~/.gemini/settings.json`, `~/.cursor/mcp.json`,
  `~/.config/amp/settings.json`). If the MCP entries Uncoil added are to be
  removed, that happens from the Extensions screen, with the plan shown first.
- Secrets in the Keychain: the user's own data.

## Privacy and telemetry

**Uncoil sends no telemetry and no crash report over the network.**

- No analytics, no usage counter, no "crash ping".
- The only things that reach the network are jobs the user asked for: the agent
  CLIs' own connections, `git fetch`, and the health check against remote MCP
  servers the user added.
- Crash reporting (`CrashReportingPolicy`) is **off by default**, and even when
  it is on it only collects local crash logs into Uncoil's debug bundle. Sharing
  that bundle is the user's decision.
- Secret values never appear in configs, diffs, logs, exports or backups; only
  the key **names** travel (`ExtensionsAcceptanceTests` verifies this).
