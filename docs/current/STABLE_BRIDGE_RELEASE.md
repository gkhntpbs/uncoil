# Stable bridge release — 0.1.1, build 4

Prepared on 2026-10-22. Publication is pending validation.

## Scope

The bridge starts from the published source branch, `origin/main` at `b8f15e2`, and adds the Stable/Edge update selector from `d1b6fec`. The source worktree is `.build-cache/stable-bridge-release`. The original `edge` worktree and its staged and unstaged changes remain intact. The 23 unpublished commits on the original local `main` and later Edge development are excluded. The preliminary worktree at `.build-cache/stable-bridge` remains untouched and is not the release source.

The installed channel is Stable. Existing and unknown preferences use Stable. Edge uses its own feed; returning to Stable waits for a newer build. The shipped Stable feed URL, bundle identifier and Sparkle public key remain unchanged.

The version is 0.1.1 and the global build is 4, above local Stable build 2 and development build 3. No `v0.1.1` release tag has been created yet.

## Recovery

Both the app repository and the local landing repository have `backup/2026-10-22-pre-stable-bridge` annotated tags containing snapshots of their working files. Their original indexes are unchanged.

Verified source archives, binary patches for working and staged changes, Git bundles and SHA-256 manifests are in `.build-cache/release-backups/20261022T191450Z`. These are local source backups, not backups of installed application data or remote copies. Existing build products remain in place.

## Validation and remaining gates

- Release tooling: 18 Python tests passed.
- Remote release inventory: only `v0.1.0` is published.
- Developer ID Application identity for team `K3TKWWVEB9` is available.
- The dependency lock is copied from the existing project: Sparkle 2.9.5 and SwiftTerm 1.15.0.
- Apple Metal Toolchain 27A266a was downloaded with explicit user approval; an export is preserved under `.build-cache/MetalToolchain`.
- The Debug build passed through XcodeBuildMCP using `.build-cache/StableBridgeDerivedData`.
- The final full unit suite passed: 1,810 passed, no failures, eight optional render samples skipped. All 24 runtime-daemon integration tests executed successfully.
- The latest complete UI smoke run passed 13 scenarios and failed `testDragSessionCreatesSplitPane`. The update-channel test passed Stable → Edge, relaunch persistence and return to Stable. The stale fixture names, missing startup route and combined accessibility groups were corrected.
- The remaining split test now reaches the actual session row, but no split pane appears after dragging. A local copy/move-mask experiment and a header-drop experiment did not resolve it; the operation-mask experiment was reverted. This is an unresolved release gate, and publication must not proceed without fixing it or an explicit user decision to defer it.
- Build and test evidence is in `.build-cache/stable-bridge-release-*.log`, with result bundles under `.build-cache/XcodeBuildMCP`.
- Computer Use acceptance, Release archive, notarization, package verification, GitHub publication and signed-feed deployment remain pending.

All build and tooling caches must remain on the external disk. The user authorized installation of the missing Metal Toolchain. Historical notes in `docs/roadmap/SPARKLE_SETUP.md` record Xcode Direct Distribution as the notarization route; no named notarytool profile was recorded.

## Publication order

Complete the build and acceptance gates, commit the Stable bridge, create its annotated tag, archive and notarize, verify the package, publish the GitHub release, then prepare and deploy the signed Stable feed. Never announce an unavailable archive. An Edge package remains a separate release.
