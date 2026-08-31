# Releasing Loomscreen

**English** · [简体中文](../zh-Hans/releasing.md)

This is the maintainer checklist for a manual `0.x` release. Public builds are
signed with an Apple Development certificate (a Team ID, so Sparkle can load)
and distributed from GitHub Releases as DMGs. They are not Developer ID signed
and are not notarized.

## Current updater boundary

Installed copies check a per-SKU Sparkle appcast (`appcast-lite.xml` /
`appcast-pro.xml` on `main`). Sparkle downloads that SKU's DMG, verifies the
EdDSA signature, and replaces the app. First launch of a newly downloaded build
still needs the quarantine-clear command — there is no notarization.

## Version checklist

1. Set `MARKETING_VERSION` to `X.Y.Z` for both app targets:
   `LiveWallpaper` and `LiveWallpaperLite`. `CFBundleVersion` tracks that
   value (Sparkle compares `CFBundleVersion`, so a frozen build number would
   hide every release).
2. Leave `CURRENT_PROJECT_VERSION` in the Xcode project alone; the app plists
   no longer read it.
3. Update `CHANGELOG.md` with `## [X.Y.Z] — YYYY-MM-DD`. It carries no footer
   compare links; adding some for one version only would leave the rest dangling.
4. Make sure `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   is included when Swift package pins changed.
5. Commit the version and documentation changes before packaging. The local
   packaging script refuses a dirty tree except for `appcast-lite.xml` and
   `appcast-pro.xml`, which it regenerates.

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
JavaScriptCore, or manual libc++ dynamic link. Sparkle is linked on
purpose. Use a fresh
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

Expected commands, Lite first so packaging order matches upload order:

```sh
scripts/release-app.sh --sku lite --version X.Y.Z --skip-checks \
  --notes-file .notes/release-notes/X.Y.Z.md
scripts/release-app.sh --sku pro  --version X.Y.Z --skip-checks \
  --notes-file .notes/release-notes/X.Y.Z.md
```

`--notes-file` is not optional in practice. Without it the appcast falls back to
the quarantine line alone, so Sparkle's update dialog says nothing about the
release while the GitHub page lists everything. Forgetting it on one SKU is easy
and silent — the packaging run still reports success.

`release-app.sh` re-runs the whole release-candidate gate for **each** SKU by
default, so an unqualified pair of commands runs it three times on one commit.
`--skip-checks` skips that repeat — use it only when the gate above already
passed on this exact commit, and say so in the release report. It does **not**
skip the per-SKU checks that matter: Sparkle helper re-signing and Team ID
alignment, signature verification, effective-entitlement inspection of the
signed app, bundle ID / display name / version fields, DMG mount and verify,
sha256, and appcast regeneration. Those are unconditional.

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

The order matters: Sparkle reads the feed from `main`, so an appcast that lands
before its DMG exists points at a 404.

```sh
# 1. Commit the appcasts both packaging runs regenerated, then tag
git add appcast-lite.xml appcast-pro.xml
git commit -m "Publish Sparkle appcast for X.Y.Z"
git tag -a loomscreen-vX.Y.Z -m "Loomscreen X.Y.Z"
git push origin loomscreen-vX.Y.Z

# 2. Upload the DMGs, so the enclosure URLs resolve
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg \
  build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --verify-tag \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>

# 3. Only now publish the feed
git push origin main
```

## Release notes

Four blocks, in this order: a download chooser, a collapsed first-launch note,
the three-section changelog, and the system requirement. English set first,
then `---`, then the equivalent Simplified Chinese set. Link definitions go at
the very bottom of the file and are shared by both languages.

````markdown
## Download

| Edition | Your Mac | Wallpapers |
| --- | --- | --- |
| [**Lite**][lite] | Intel or Apple Silicon | Video · Web |
| [**Pro**][pro] | Apple Silicon | Video · Web · **Wallpaper Engine scenes** |

<details>
<summary><b>First launch</b> — if macOS says the app is damaged</summary>

Nothing here is notarized, so a DMG downloaded by hand is quarantined and macOS
may refuse to open it. If that happens, run this once:

```sh
xattr -dr com.apple.quarantine /Applications/Loomscreen.app
```

For Pro:

```sh
xattr -dr com.apple.quarantine "/Applications/Loomscreen Pro.app"
```

Once is enough — updates Loomscreen installs itself clear the flag, so later
versions open straight away.

</details>

## What's New

- <user-visible capability that did not exist before>

## Improvements

- <existing behavior that got better, faster, or clearer>

## Bug Fixes

- <what was broken, in the user's words; reference an issue when there is one>

Requires macOS 14.6+.

<!-- bottom of file -->
[lite]: https://github.com/Paradox07127/macos-wallpaperengine/releases/download/loomscreen-vX.Y.Z/Loomscreen-X.Y.Z.dmg
[pro]: https://github.com/Paradox07127/macos-wallpaperengine/releases/download/loomscreen-vX.Y.Z/Loomscreen-Pro-X.Y.Z.dmg
````

Details that have bitten before:

- **Lite gets one row reading "Intel or Apple Silicon"** — it ships universal
  (`x86_64 arm64`), so one file covers both. Do not split it per architecture
  (tried and reverted on 2026-08-30: the same link twice reads as a mistake).
  Pro is `arm64` only, so its row says Apple Silicon. Take the architecture claim
  from this release's `lipo -archs`, not from last release's notes.
- **The first-launch block is a fallback, not an instruction.** Measured 2026-08-30:
  Sparkle 2.9.6 clears `com.apple.quarantine` on what it installs, so a user who ran
  the command once never runs it again across updates. Phrase it as "if macOS refuses
  to open it", and say the flag is cleared by in-app updates. It cannot be dropped
  entirely — a hand-downloaded DMG still arrives quarantined, and
  `release_contract_check.sh` asserts the command is present in the appcast.
- **Leave a blank line after `</summary>`** or GitHub will not render the markdown
  inside `<details>`.
- **One-click copy is just a fenced code block** — GitHub adds the copy button.
  Keep Lite and Pro in separate blocks so each gets its own button.
- Changelog items come from what actually shipped in `git log <previous-tag>..HEAD`,
  picking what a user would notice. This is a changelog, not a summary of every
  commit, and not a rewording of `CHANGELOG.md`. Drop any section with nothing in it.
- Equivalent means equivalent: version numbers, command lines, paths, and the SKU
  names (Loomscreen / Loomscreen Pro) stay identical and untranslated, and neither
  language omits an item the other has. The Chinese headings are 新功能 / 改进 / Bug 修复.
- Still out: a marketing tagline or lead paragraph, and per-subsystem headings.
  The download and first-launch blocks *are* wanted — but only in the table and
  collapsed form above, never as prose paragraphs.

This file is the single source for both surfaces. `gh release create --notes-file`
renders the release page from it, and `scripts/generate-appcast.sh --notes-file`
lifts the three changelog sections — English half only, everything before the
`---` — into Sparkle's update dialog. The download table, the collapsed block and
the Chinese half never reach the dialog: an updater that is already downloading
does not need a download table, and the pane is only 565x402. Write the notes
*before* packaging, because `release-app.sh --notes-file` passes them to the
appcast generator at package time; omitting the flag silently falls back to a
dialog carrying nothing but the quarantine line.

## Post-release verification

Confirm the upload survived the trip — the only evidence that GitHub holds the
bytes that were signed here:

```sh
gh release view loomscreen-vX.Y.Z --json tagName,assets \
  --jq '.tagName, (.assets[] | "\(.name) \(.size)")'
gh release download loomscreen-vX.Y.Z --pattern 'Loomscreen-X.Y.Z.dmg' --clobber
shasum -a 256 Loomscreen-X.Y.Z.dmg   # must equal build/release/Loomscreen-X.Y.Z.dmg.sha256
```

Then smoke the build itself:

1. Install the Lite DMG on a clean Mac.
2. Run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
3. Launch Loomscreen and confirm the menu bar app opens.
4. In **Settings -> About**, confirm the version is `X.Y.Z`.
5. Confirm **Check Now** talks to Sparkle (not an error, not a false
   “up to date” before the appcast is on `main`).
