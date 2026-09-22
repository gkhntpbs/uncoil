# Stable and Edge delivery

Status: phases 1–3 implemented locally, phase 4 tooling in place; phase 5
and every publishing step pending. Baseline inspected on
2026-09-22. Nothing has been published: every release tag, build number and feed
change described below still stops at the local working tree.

## Product contract

`edge` is the development branch. Tested and accepted changes are promoted to
`main`, the stable release branch. Existing `backup/*` refs remain recovery
points. Stable and Edge are update preferences in one application, with the
existing bundle identifier, signing identity, Sparkle public key and user data.
They are not separate installations.

Settings → About will offer Stable and Edge. Existing installations default to
Stable. Edge is an explicit choice, survives relaunch and follows subsequent
Edge releases. Changing back to Stable follows future stable releases; it does
not install an older build or roll back the user's data. Explain this beside
the selector. Disable channel changes during an active update session.

The existing production feed remains `/appcast.xml`. Edge uses a separate
`/appcast-edge.xml`. No Edge package may enter the stable feed. Feed selection
uses Sparkle's updater delegate; do not mutate the shipped stable URL or use
the deprecated persisted feed URL setter. A channel change resets Sparkle's
update cycle; manual checking remains available and installation requires the
existing Sparkle confirmation.

## Verified baseline

- The live stable feed advertises 0.1.0, build 1, with a signed GitHub zip.
- `project.yml` is locally 0.2.0, build 2; `v0.2.0` is a local tag. A tag alone
  does not establish that a package was published.
- The remote source repository currently has only `main`. Local `main` has
  23 commits beyond `origin/main`; preserve that history during publication.
- `gkhntpbs/uncoil-landing` is a separate private repository. Its main branch
  deploys the website. Its local checkout has not yet been located or cloned.
- `UpdaterService` wraps Sparkle and does not yet have channel selection.
- This session exposes XcodeBuildMCP simulator tools, but not `build_macos`,
  `test_macos` or `launch_mac_app`. Resolve this before visual acceptance;
  shell checks are not a replacement for the mandated macOS workflow.

## Phase 1 — Recovery and branch consolidation

- [x] Commit the existing modified string catalog and both untracked
  simplification documents without altering their content.
- [x] Annotated backup tag: `backup/2026-09-22-pre-edge-consolidation`,
  snapshot commit `9263da8`.
- [x] Fast-forward `edge` to that snapshot. Verify every retired development
  branch's committed tip is an ancestor of `edge`; leave `main` unchanged.
- [x] Remove merged `simplify/phase-0`, `simplify/phase-1`, `simplify/phase-3` refs.
- [x] Preserve both daily worktrees and their staged files. Snapshot each
  index with `git commit-tree` and an annotated
  `backup/2026-09-22-<name>-working-state` tag. Rename their branches to
  `backup/claude-daily` and `backup/codex-daily` without changing files or indexes.
  Their historical staged documentation is archived, not merged over current
  documentation. All committed work was already an ancestor of `edge`.
- [x] Allocate the next build above both the current build and every local
  stable/Edge release tag, regardless of marketing-version ordering. Fail
  without changing `project.yml` when a release tag has an invalid build.
- [x] Six isolated script tests cover both mutation commands, cross-channel
  allocation, version ordering, backups and malformed release metadata.

Backup tags cover source and staged work, not ignored build caches or runtime
application data. All refs are local until explicitly pushed.

## Phase 2 — Application channel selection

- [x] Add a small typed Stable/Edge preference with unknown-value fallback to
  Stable, isolated storage for tests and a single feed mapping.
- [x] Implement the Sparkle delegate and retain it for the updater lifetime.
  Check session state in the setter as well as disabling the picker, so a
  concurrent check cannot redirect an in-progress installation.
- [x] Add the picker and explanatory text to the existing Software Update
  section in About, plus English/Turkish strings and searchable settings terms.
- [x] Keep UI fixtures free of network requests while making the channel UI
  available for deterministic testing.
- [x] Test default/fallback behavior, persistence, feed mapping, busy-session
  rejection and switching back to Stable without enabling downgrades.
- [x] The Uncoil unit suite builds and passes against external
  `.build-cache/DerivedData`, including six channel tests.
- [ ] Visual acceptance is outstanding: the UncoilUI relaunch test
  (`testUpdateChannelPersistsAcrossRelaunch`) and the 1100×720 fixture — both
  choices and relaunch persistence — have not been run and belong to the user.

## Phase 3 — Versioning and release packaging

Keep `MARKETING_VERSION` numeric (`x.y.z`) for bundle compatibility. Introduce
an explicit release-channel value in `project.yml`, compiled into the bundle
so About can identify the installed package separately from the selected
update preference. Stable tags remain `vX.Y.Z`; Edge tags are
`vX.Y.Z-edge.BUILD`. A stable repackage must get a fresh patch version and build,
so no published tag or asset needs replacement.

- [x] Extend version diagnostics and release preflight for both tag forms,
  channel/branch consistency, annotated tag at HEAD and clean source state.
- [x] Fetch and verify remote release refs before reserving a build; use the
  global maximum implemented in phase 1. Serialize publication to prevent two
  machines from reserving the same number. Local allocation alone is not a
  distributed reservation.
- [x] Include the channel and build in Edge artifact and notes filenames.
  Validate the exported bundle's version, build and channel against its tag.
- [x] Keep CHANGELOG as the notes source. Add distinct Edge release sections
  and support extracting notes by the full release identity.
- [x] Publish in `gkhntpbs/uncoil`: Edge releases are GitHub prereleases with
  latest disabled; Stable releases are normal releases. Keep immutable assets,
  checksums, Developer ID signing, notarization and Sparkle signatures.
- [x] Generate each feed only from its own packages; preserve existing items
  and their correct per-tag download URLs. Verify all advertised assets exist
  before allowing the landing repository to publish.
- [x] Test branch/tag/channel mismatches, build reuse, missing signatures,
  nonexistent assets and accidental stable-feed changes in an Edge release.

Where this lives: `scripts/release_metadata.py` owns release identity, build
allocation, the tag ledger and preflight; `scripts/publish_release.py` verifies
the signed, stapled package and creates the GitHub release; `scripts/validate_appcast.py`
and `scripts/prepare_feed.py` generate and check a feed per channel;
`scripts/version.sh` and `scripts/release.sh` call into them. Twelve script
tests cover identity, preflight and feed validation. None of this has been run
against the real remote yet — phase 4 is the first time it touches a server.

## Phase 4 — Landing repository and rollout

- [x] Cloned to `../uncoil-landing`; README, deploy workflow and page
  generator read before editing. Deploy is a push to `main`; the server does
  `git reset --hard` + `git clean -fd`, so the feed must live in that repo.
- [ ] Preserve the deployed stable feed byte-for-byte while adding the first
  signed Edge feed and versioned notes through the existing deployment path.
  The machinery is in place and refuses to touch `appcast.xml`; no Edge feed
  has been generated yet, because no Edge package has been built.
- [x] `scripts/build-edge-page.py` generates `/edge/` from the Edge feed
  itself — never hand-written, refuses an empty feed, and errors if the page
  exists without a feed. The hand-written home page and its Download button
  are untouched.
- [ ] Discovery is deliberately still off: no link to `/edge/` from the nav or
  footer until the first Edge package and feed are live.
- [x] `scripts/verify-feeds.py` in the landing repo replaces the workflow's
  inline appcast check: valid RSS, nonempty, a 64-byte EdDSA signature per
  item, channel isolation by tag shape, and a HEAD against every advertised
  package with a length match. The Edge feed is checked only when the repo
  carries one — until then a 404 is the right answer. Verified against the
  live stable feed: one signed item, package downloadable, sizes agree.
- [ ] Publish the first Edge package, then its feed, then enable discovery.
- [ ] Deliver a minimal stable bridge release containing channel selection so
  already installed 0.1.0 clients can opt in through the app. That release must
  be built from stable plus the verified updater change, not the entire
  unaccepted simplification branch. Old binaries cannot acquire a settings
  picker through a feed-only change.

## Phase 5 — Promotion and acceptance

- [ ] Exercise stable → Edge, Edge → newer Edge, relaunch persistence and
  Edge → Stable preference change using signed packages and isolated data.
- [ ] Confirm an existing stable client never sees an Edge package.
- [ ] Verify failed downloads/signatures do not replace the installed app and
  unavailable Edge feeds report failure without silently changing channel.
- [ ] Promote accepted changes from `edge` to `main`, allocate a globally newer
  build, rerun the release gates, publish Stable and then its feed. Merge any
  stable-only release fixes back into `edge`.
- [ ] Verify website, GitHub release identity, packaged metadata and feed build
  numbers agree. Record the installation and runtime compatibility evidence.
- [ ] Document withdrawing a bad feed item and publishing a newer repair;
  keep immutable GitHub artifacts and do not automatically downgrade data.

Publishing, notarization and the landing deploy remain explicit release steps.
This plan starts implementation locally and does not publish a package.
