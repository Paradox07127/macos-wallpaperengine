# Releasing Loomscreen

**English** · [简体中文](../zh-Hans/releasing.md)

This is the maintainer checklist for a manual `0.x` release. Public builds are
ad-hoc signed and distributed from GitHub Releases as DMGs.

## Current updater boundary

Release delivery uses GitHub Releases and remains manual: users download the
new DMG and replace the installed app. Both SKUs run the launch-time and
About-panel GitHub update checks; neither auto-installs updates.

## Version checklist

1. Set `MARKETING_VERSION` to `X.Y.Z` for both app targets:
   `LiveWallpaper` and `LiveWallpaperLite`.
2. Keep `CURRENT_PROJECT_VERSION` unchanged unless the build-number policy
   changes.
3. Update `CHANGELOG.md` with `## [X.Y.Z] — YYYY-MM-DD` and footer compare
   links.
4. Make sure `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   is included when Swift package pins changed.
5. Commit the version and documentation changes before packaging. The local
   packaging script refuses a dirty tree.

## Preflight

Run the complete sequential gate before creating artifacts:

```sh
scripts/release_candidate_check.sh
```

The script runs the Core and ProWPE package tests, signed Pro tests,
the four-surface link matrix (Pro Debug/Release and Lite Debug/Release),
Pro and Lite Release archive smokes, release build-setting/privacy checks, and
`git diff --check`. Every Xcode action uses
`SWIFT_EMIT_LOC_STRINGS=NO`. Package, Pro, and Lite checks are deliberately
sequential with isolated build databases to avoid compiler/build database
contention.

For a reproducible verification run, keep all transient products outside the
repository:

```sh
DERIVED_DATA=/tmp/LoomscreenReleaseCandidate-arm64 \
  scripts/release_candidate_check.sh
```

The Pro and Lite smoke archives default to
`/tmp/LoomscreenReleaseCandidate-arm64ProRelease/LiveWallpaper-LinkMatrix.xcarchive`
and
`/tmp/LoomscreenReleaseCandidate-arm64LiteRelease/Loomscreen-LinkMatrix.xcarchive`.
They are ad-hoc signed only to exercise the real archive/signing path. Pro must
contain exactly arm64; Lite must contain arm64 and may additionally carry
x86_64, since Lite ships universal for Intel Macs. Both need valid nested
signatures. Pro must
embed exactly one XPC service, `SteamConnector.xpc`, and it must carry **no**
App Sandbox entitlement — an unsandboxed helper is the whole point, since a
sandboxed one would put its STEAMROOT back in the app container and silently
undo the Steam-library migration. (The SceneScript XPC helper this paragraph
used to describe retired on 2026-07-23.) Lite must contain no embedded XPC
service at all, and no Pro renderer/SceneScript symbols,
JavaScriptCore, Sparkle, or manual libc++ dynamic link. Use a fresh
`DERIVED_DATA`/archive path for each run; the gate refuses to delete or
overwrite an existing archive.

These ad-hoc archives are verification evidence, **not shipping entitlement
artifacts**. Xcode's “Sign to Run Locally” path may inject
`get-task-allow=true`, and `scripts/check_entitlements.sh --app` must reject that
shape. Effective Pro/Lite shipping entitlement approval, Developer ID trust,
and notarization must run on the signing Mac against the final Developer ID
archives; do not waive that failure or substitute the link-matrix archive.

## Manual packaging

The tracked, secret-free packaging helper produces:

- `build/release/Loomscreen-X.Y.Z.dmg`
- `build/release/Loomscreen-X.Y.Z.dmg.sha256`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256`

Packaging requires `create-dmg` on the packaging Mac:

```sh
brew install create-dmg
```

It lays out the mounted DMG window (background, icon positions, `/Applications`
drop link). The window background is rendered per SKU by
`scripts/dmg_background.swift`, which bakes the SKU's app name into the
Gatekeeper command shown on the image — that is why it is generated at package
time instead of committed as a static PNG.

Expected commands:

```sh
scripts/release-app.sh --sku lite --version X.Y.Z
scripts/release-app.sh --sku pro  --version X.Y.Z
```

Validate the clean-clone tooling contract without building or signing:

```sh
scripts/release_contract_check.sh
scripts/release-app.sh --sku lite --version X.Y.Z --plan
scripts/release-app.sh --sku pro  --version X.Y.Z --plan
```

`--plan` performs no build and writes no artifact. Signing identities and any
future notarization credentials remain environment/machine inputs; they are not
stored in this repository.

The public Lite asset must be named `Loomscreen-X.Y.Z.dmg`. The Pro asset must
be named `Loomscreen-Pro-X.Y.Z.dmg`. Asset order does not affect the in-app
check — it reads the release tag, never the asset list — but keep the Lite DMG
first so the release page leads with the public download.

## GitHub release

Create one unified release:

```sh
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg \
  build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>
```

Release notes should lead with the Lite download and mention that updating is
manual: download the new DMG, replace the app in `/Applications`, then repeat
the quarantine-clear command once.

## Post-release smoke

1. Install the Lite DMG on a clean Mac.
2. Run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
3. Launch Loomscreen and confirm the menu bar app opens.
4. In **Settings -> About**, confirm the version is `X.Y.Z`.
5. Confirm **Check Now** resolves the current version through GitHub Releases.
