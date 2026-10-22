# Stable bridge release — 0.1.1, build 4

Prepared on 2026-10-22. Published as Stable 0.1.1, build 4, after local validation and Apple notarization.

## Scope

The bridge starts from the published source branch, `origin/main` at `b8f15e2`, and adds the Stable/Edge update selector from `d1b6fec`. The source worktree is `.build-cache/stable-bridge-release`. The original `edge` worktree and its staged and unstaged changes remain intact. The 23 unpublished commits on the original local `main` and later Edge development are excluded. The preliminary worktree at `.build-cache/stable-bridge` remains untouched and is not the release source.

The installed channel is Stable. Existing and unknown preferences use Stable. Edge uses its own feed; returning to Stable waits for a newer build. The shipped Stable feed URL, bundle identifier and Sparkle public key remain unchanged.

The version is 0.1.1 and the global build is 4, above local Stable build 2 and development build 3. The annotated release tag is `v0.1.1`.

## Recovery

Both the app repository and the local landing repository have `backup/2026-10-22-pre-stable-bridge` annotated tags containing snapshots of their working files. Their original indexes are unchanged.

Verified source archives, binary patches for working and staged changes, Git bundles and SHA-256 manifests are in `.build-cache/release-backups/20261022T191450Z`. These are local source backups, not backups of installed application data or remote copies. Existing build products remain in place.

## Validation and remaining gates

- Release tooling: 18 Python tests passed.
- GitHub release `v0.1.1` is published as Stable/latest with the verified ZIP and SHA-256 asset.
- Developer ID Application identity for team `K3TKWWVEB9` is available.
- The dependency lock is copied from the existing project: Sparkle 2.9.5 and SwiftTerm 1.15.0.
- Apple Metal Toolchain 27A266a was downloaded with explicit user approval; an export is preserved under `.build-cache/MetalToolchain`.
- The Debug build passed through XcodeBuildMCP using `.build-cache/StableBridgeDerivedData`.
- The final full unit suite passed: 1,810 passed, no failures, eight optional render samples skipped. All 24 runtime-daemon integration tests executed successfully.
- The drag test used XCTest's touch-event `press` API on macOS. It now uses `click(forDuration:thenDragTo:)` on the actual session row. All experimental application drag code was removed.
- The final full UI suite passed: 14 tests, no failures or skips. The update-channel scenario passed Stable → Edge, relaunch persistence and return to Stable.
- Computer Use verified the isolated 1100×720 Debug dashboard and both channel explanations. The final notarized Release app was also checked on the project dashboard, session and About page, showing Stable 0.1.1 (4).
- The Release archive passed XcodeBuildMCP. The approved Developer ID / notarization upload completed successfully through Xcode's existing Alparslan Topbas account. The exported app passed deep strict code-signing verification, Gatekeeper assessment as Notarized Developer ID, stapled-ticket validation and release metadata checks. Application source inputs are unchanged since candidate commit `bf587f2`; the final changes only affect tests and this record.
- Build and test evidence is in `.build-cache/stable-bridge-release-*.log`, with result bundles under `.build-cache/XcodeBuildMCP`.
- The signed Stable feed and release pages were deployed from landing commit `e369d74`; GitHub Actions run `39848247678` passed. The feed preserves build 1 and adds build 4.
- Public package SHA-256: `572541807136268c141b4d241f459ed7e0bab2137bf7cbe1ca13ad20921d1438`.
- Real installation through Sparkle on an existing user installation or a clean Mac was not exercised. The Edge package/feed remains unpublished.

All build and tooling caches must remain on the external disk. The user authorized installation of the missing Metal Toolchain. Historical notes in `docs/roadmap/SPARKLE_SETUP.md` record Xcode Direct Distribution as the notarization route; no named notarytool profile was recorded.

## Publication order

Complete the build and acceptance gates, commit the Stable bridge, create its annotated tag, archive and notarize, verify the package, publish the GitHub release, then prepare and deploy the signed Stable feed. Never announce an unavailable archive. An Edge package remains a separate release.
