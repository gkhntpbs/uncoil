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

Developer ID signing, notarization, packaging, GitHub Releases and feed
generation are scripted (see *Stable and Edge* below). CI workflows are not:
every publishing step is run by hand, on an explicit command. The Edge feed has
no published package yet.


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

## The update mechanism

**Sparkle, with the user in charge.** The original decision here was "no
Sparkle"; it was revisited once the first public release made a manual
check-and-redownload loop a real cost for every installed copy. What made the
revisit acceptable is that the original objections were answered rather than
overruled:

- Sparkle is MIT and joined SwiftTerm as the second and last dependency.
- Nothing installs quietly. The app checks the feed once a day, tells the user
  only when there is something to install, and installs nothing without an
  explicit yes. The check itself can be turned off in Settings › About.
- Every update is verified twice before it runs: the EdDSA signature in the
  appcast (only our Sparkle key can produce it) and the notarized Developer ID
  signature inside the zip.

The feed lives at `https://uncoil.gokhantopbas.com/appcast.xml` and is served
from the landing-site repository, where every change to it is a reviewable
commit.

## Stable and Edge

Uncoil has two update channels and one application. Stable is the default and
what an existing installation stays on; Edge takes a release as soon as it is
cut, before acceptance. The channel is a preference in Settings › About, not a
second installation: same bundle identifier, same signing identity, same
Sparkle key, same user data. Sparkle's updater delegate answers with the
channel's feed, so the `SUFeedURL` shipped in `Info.plist` never changes and an
old build keeps checking the stable feed exactly as before.

- Feeds: `https://uncoil.gokhantopbas.com/appcast.xml` (Stable) and
  `/appcast-edge.xml` (Edge). Each feed is generated only from its own
  packages; an Edge package never enters the stable feed.
- Branches: Stable is cut from `main`, Edge from `edge`.
- Tags: `vX.Y.Z` for Stable, `vX.Y.Z-edge.BUILD` for Edge. `MARKETING_VERSION`
  stays numeric either way, because the bundle version has to be.
- `UNCOIL_RELEASE_CHANNEL` in `project.yml` is compiled into the bundle, so
  About can say which channel the running copy came from regardless of which
  channel the user is currently subscribed to.
- The build number is global: `scripts/version.sh` allocates above every
  Stable *and* Edge tag, so promoting to Stable can never reuse a number an
  Edge package already published.

## Publishing the update feed

Order matters: the appcast must never announce a version that cannot be
downloaded yet. Publish the package first, the feed second.

1. `scripts/release.sh --package <app>` (or `--notarize`) builds, verifies and
   zips. It refuses a bundle whose version, build, channel or Sparkle key does
   not match the tag being released.
2. `python3 scripts/publish_release.py <zip>` re-verifies the signature,
   notarization ticket and stapling, reserves the build number remotely so two
   machines cannot claim it, pushes the tag and creates the GitHub release —
   a prerelease with `latest` disabled for Edge, a normal release for Stable.
   It uploads a SHA-256 next to the zip and only leaves draft state once the
   uploaded asset's digest and size match the local file.
3. `python3 scripts/prepare_feed.py --landing <landing-repo> --archive <zip>`
   generates the channel's feed with `generate_appcast`, verifies the EdDSA
   signature against the shipped public key, checks that every advertised
   asset actually answers, and refuses to change either an existing feed item
   or the stable feed. It stages the feed and the `Uncoil-<identity>.html`
   notes in the landing repository's `public/`; committing and deploying that
   repository is a separate, explicit act.

Release notes are written once, in `CHANGELOG.md`. A section heading carries
the full release identity (`## [0.3.0-edge.7]` for Edge), and the scripts read
the notes from there — there is no second place to keep them in sync.

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
