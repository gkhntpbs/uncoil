# Uncoil release pipeline

Uncoil does not currently have an automated public release workflow. This document defines the release gate for signed local builds and the work required before distribution is enabled.

## Build inputs

- Generated project source: `project.yml`
- Scheme: `Uncoil`
- Configuration: `Release`
- Destination: `platform=macOS,arch=arm64`
- DerivedData: `.build-cache/DerivedData`
- Development team: `K3TKWWVEB9`
- Bundle identifier: `com.gkhntpbs.uncoil`

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
"xcodegen" generate
xcodebuild -project Uncoil.xcodeproj -scheme Uncoil -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build-cache/DerivedData build
```

## Distribution status

Notarization, Developer ID signing, DMG packaging, update feeds, GitHub Releases, and CI workflows are not implemented. Do not publish a build until those steps have explicit credentials, automation, rollback instructions, and a successful clean-machine installation test.

The files under `docs/history/` describe a historical third-party release system. They are not commands or configuration for Uncoil.
