# Update channel and settings compatibility

Stable 0.1.2 (build 5) and Edge 0.2.0-edge.6 (build 6) include the same settings compatibility fix. Edge also includes the current development work captured by `backup/2026-10-23-edge-release-candidate`; the original development working tree and index are preserved.

The previous Stable reader decoded all settings in one operation. An account from a newer build with an unknown provider invalidated the entire document. Startup then created default accounts and saved those defaults over the original settings, including the onboarding stamp.

Settings now load each known field against the schema's defaults. Supported accounts remain available; unknown account records and unknown top-level fields survive saves. Nested fields are retained when unrelated preferences change or a default-valued group is omitted by the older encoder. Unsupported preferences remain in the document while the older build uses a fallback. A deliberate replacement of a supported preference replaces that fallback. A settings file that cannot be read as a JSON object is never overwritten by startup or subsequent saves.

Before a compatibility conversion writes settings, it preserves the original bytes beside the file as `settings-before-migration-<SHA256>.json` with mode 0600. Identical backups are reused. A backup failure prevents the conversion write. Loading the interface language no longer saves a partially restored settings document.

Stable and Edge use the same bundle identifier and application-support directory. Switching a channel immediately starts Sparkle's user-initiated update check, including when scheduled checks are disabled. The selected channel is persisted. Installing a release still requires the user's confirmation. A feed must refer to an existing signed package, and builds must increase across both channels. Stable never installs an older build over a newer Edge build.

A source branch is not itself an update package. Each Edge release must be built, signed, notarized, uploaded and added to the signed Edge feed. Future branch changes become available only after that release process succeeds.

Already overwritten settings cannot be reconstructed from a reset file alone. Recovery requires a copy from before the reset; this fix does not claim to recover data that is no longer present.
