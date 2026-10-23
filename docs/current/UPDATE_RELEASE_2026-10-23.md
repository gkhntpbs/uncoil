# Update channel release — 2026-10-23

Stable 0.1.2 (build 5) and the first Edge package, 0.2.0-edge.6 (build 6), are published. Stable remains the GitHub latest release. The Edge package includes the pending Uncoil Auto/Codex development captured for this release.

## Publication

- Stable source tag: `v0.1.2`, commit `8a7d5ed`.
- Edge source tag: `v0.2.0-edge.6`, commit `72dde3c`.
- Landing deployment: `337bef86fb7f8a7fb9b04b9731128f21e1c18ed0`; GitHub Actions run `40003678199` passed.
- Stable feed contains builds 1, 4 and 5. Edge feed contains build 6. Previous Stable entries are unchanged.
- Both packages passed Developer ID signing, Apple notarization, stapled-ticket validation and Gatekeeper assessment. The exported application inputs match the validated source inputs.
- Stable archive SHA-256: `94cdb880f45d6281656f1c26a1dac43bd5612ac1ab3fb23808d12713ce30ff1d`.
- Edge archive SHA-256: `28347b7dfd63dfb58c581b4018072d9fbc0fd78e129e10f6e11919d8014a358c`.
- Both public archives were downloaded and matched these hashes. Live feeds, notes and pages matched the deployed source after accounting for existing Cloudflare HTML transformations.

## Validation

- Stable: 1,814 unit tests passed, eight optional samples skipped; 14 UI tests passed, with channel persistence checked again after the final settings fix.
- Edge: 2,633 unit tests passed, 23 optional tests skipped; all 15 UI tests passed in the final complete run, including the handoff fixture and channel relaunch persistence.
- Release tooling: 18 tests passed.
- Computer Use checked the notarized Release applications on project, session and About screens. Installed channel/version and the separate selected update channel were visible.
- Edge test contracts now distinguish the installed CLI's native `--approve-for-me` flag from the separately gated legacy app-server contract. The long socket fixture resolves to the external short cache. The palette test uses a deterministic search prefix because XCTest's synthetic full word triggered the project's keyboard shortcut; the real palette flow was also checked with Computer Use.
- Real installation through Sparkle on a user installation or a clean Mac was not exercised. UI fixtures intentionally disable Sparkle startup. The failed standalone GUI home-isolation probe was not used as acceptance evidence; `CFFIXED_USER_HOME` alone does not isolate the production preferences domain.

## Recovery and development checkout

Local source bundles, release packages, feed copies and manifests are in `.build-cache/release-backups/20261023-update-channels`. The local settings and top-level state JSON copies are private and were not uploaded. Older source backups remain under `.build-cache/release-backups/20261022T191450Z`.

The original checkout remains on `edge` at `6c98eb4`, with its original index intact. Its application files and release metadata now match the published Edge inputs. The release was committed and published from `.build-cache/edge-release`; its remote history includes the preserved pending work. Do not reset the dirty original checkout or force-push it when continuing development. Local `main` tracks the published Stable history; the earlier unpublished main remains preserved in `backup/main-before-stable-bridge`.

Already overwritten settings require a pre-reset backup for recovery. This release protects compatible existing settings and future compatibility writes; it cannot reconstruct data absent from the current file.
