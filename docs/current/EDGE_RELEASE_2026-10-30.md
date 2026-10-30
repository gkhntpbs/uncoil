# Edge 0.4.0, build 8

Release identity: `0.4.0-edge.8`. Release notes are maintained in the corresponding section of `CHANGELOG.md` and reused for GitHub and Sparkle.

This release includes project folders and wider/full-title sidebar presentation, shared file-drop handling, hover help and handoff controls, Turkish localization updates, browser viewport/driver capabilities, Claude usage credential recovery, unused weekly quota reminders and optional Auto preference, and background project process supervision with menu-bar controls.

The user explicitly requested skipping automated and interface tests for this Edge publication. Local Debug and Release compilation passed before the release cut; runtime lifecycle, quota notifications, provider authentication, complete title recovery, and clean-machine Sparkle installation have not received full acceptance. Signing, notarization, package integrity and update-feed verification are distribution checks rather than functional acceptance.

The Edge branch, prerelease, release notes and Edge update feed have been published. Stable remains unchanged.

Source/index/history backup: `.build-cache/release-backups/20261030-edge-8`.

## Publication verification

- Release: https://github.com/gkhntpbs/uncoil/releases/tag/v0.4.0-edge.8
- Tagged application source: `a0ce720fd2502ef30a25cd77750af62127c99b73`.
- Landing deployment: `478c94b48763e41caf00a44b6cfa544a7946cae8`; Actions run `40997176088` succeeded.
- Developer ID signatures, hardened runtime, Apple notarization, stapled ticket, Gatekeeper assessment and Sparkle EdDSA signature passed.
- Published ZIP SHA-256: `63e21e0ed1c3d2d93ed32d6fb73630dc659c0423d6b6e69c62f3dfb6b5858442`. A fresh public download matched the local package.
- Live Edge feed matches deployed source and contains builds 8, 7 and 6. Live release notes match the changelog, and the Edge page links to the new package.
- Stable remains GitHub Latest at `v0.1.2`; the live Stable feed is byte-for-byte unchanged.
- Automated and UI tests were skipped at the user's request. Distribution checks do not establish full functional or Sparkle installation acceptance.

## Development checkout preservation

The original checkout remains on its previous Edge HEAD with its working files and index preserved. Release work was committed and published from `.build-cache/edge-0.4.0-8-release`; do not reset or force-push the original dirty checkout. The tagged package is immutable; this publication record may be followed by a documentation-only Edge commit.

Local verification report: `.build-cache/release-backups/20261030-edge-8/publication-verification.json`.
