# Releasing Loomscreen

**English** · [简体中文](../zh-Hans/releasing.md)

This is the maintainer checklist for a manual `0.x` release. Public builds are
signed with the team's Developer ID Application certificate, notarized, and
distributed from GitHub Releases as DMGs. The app and the DMG each carry a
stapled notarization ticket, so Gatekeeper opens a downloaded copy without a
Terminal step. Releases up to 0.9.3 used Apple Development signing
and were not notarized.

The following DMG workflow applies to Pro and Lite. The third target, `LoomscreenAppStore`, uses a separate [App Store release workflow](app-store.md); increment its `CURRENT_PROJECT_VERSION` for every upload.

## Current updater boundary

Installed copies check a per-SKU Sparkle appcast (`appcast-lite.xml` /
`appcast-pro.xml` on `main`). Sparkle downloads that SKU's DMG, verifies the
EdDSA signature, and replaces the app. A manually downloaded build opens
directly because it is notarized.

## Version checklist

1. Set `MARKETING_VERSION` to `X.Y.Z` for both app targets:
   `LiveWallpaper` and `LiveWallpaperLite`. `CFBundleVersion` tracks that
   value (Sparkle compares `CFBundleVersion`, so a frozen build number would
   hide every release).
2. Leave `CURRENT_PROJECT_VERSION` unchanged for these two DMG targets; their plists
   use the marketing version. The App Store plist reads its own build number.
3. Update `CHANGELOG.md` with `## [X.Y.Z] — YYYY-MM-DD`. It carries no footer
   compare links; adding some for one version only would leave the rest dangling.
4. Make sure `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   is included when Swift package pins changed.
5. Commit the version and documentation changes before packaging. The local
   packaging script refuses a dirty tree except for `appcast-lite.xml` and
   `appcast-pro.xml`, which it regenerates.

## Preflight

Run `make verify` for the normal integration checks, then the complete
sequential release gate before creating artifacts:

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
DERIVED_DATA="$(mktemp -d -t LoomscreenReleaseCandidate)" \
  scripts/release_candidate_check.sh
```

The Pro and Lite smoke archives use a fresh system temporary directory per run,
which the script removes after validation. The required gate needs no personal
Workshop library; external producer/oracle acceptance runs separately as described
in [Building](building.md#external-producer-and-workshop-acceptance).
They are ad-hoc signed only to exercise the real archive/signing path. Pro must
contain exactly arm64; Lite must contain arm64 and may additionally carry
x86_64, since Lite ships universal for Intel Macs. Both need valid nested
signatures. Both SKUs embed `WallpaperMaintenance.xpc`, which runs `lsregister`
and restarts WallpaperAgent for the system wallpaper extension; Pro additionally
embeds `SteamConnector.xpc`, and neither service may carry an App Sandbox
entitlement — an unsandboxed helper is the whole point, since a sandboxed
SteamConnector would put its STEAMROOT back in the app container and silently
undo the Steam-library migration, and a sandboxed maintenance helper could not
reach `lsregister`. (The SceneScript XPC helper this paragraph used to describe
retired on 2026-07-23.) Lite must contain no other embedded XPC service, and no
Pro renderer/SceneScript symbols,
JavaScriptCore, or manual libc++ dynamic link. Sparkle is linked on
purpose. Use a fresh
`DERIVED_DATA`/archive path for each run; the gate refuses to delete or
overwrite an existing archive.

These ad-hoc archives are verification evidence, **not shipping entitlement
artifacts**. Xcode's “Sign to Run Locally” path may inject
`get-task-allow=true`, and `scripts/check_entitlements.sh --app` must reject that
shape. Validate effective Pro/Lite entitlements and nested signatures on the signing
Mac against the final Developer ID-signed shipping apps; `release-app.sh` does
this and also notarizes and staples them. Do not substitute the ad-hoc smoke archive
for a shipping artifact or waive a `get-task-allow` failure.

## Documentation and UI media

Before packaging a release with UI changes:

- Update both root READMEs and matching English/Simplified Chinese guides. Check
  navigation labels against the built app, including Lite's available pages.
- Capture the actual release candidate: display overview with shelf, unified
  library, display playback editor, combined overlay canvas, and Pro Workshop.
  Record the build and appearance used; check minimum window size and long labels.
- Use only redistributable wallpaper artwork and inspect captures for local
  paths, account details, API keys and other private information.
- Replace or remove obsolete screenshots in README/documentation. Keep prototype
  HTML and design mockups out of product screenshots. A capture does not prove
  playback, accessibility or performance correctness.
- Use [Copy Kit](press-kit.md) for promotional posts; release notes retain the
  change-only format below.

## Manual packaging

The tracked, secret-free packaging helper produces:

- `build/release/Loomscreen-X.Y.Z.dmg`
- `build/release/Loomscreen-X.Y.Z.dmg.sha256`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256`

Packaging requires Python 3.10+ and the pinned `dmgbuild` tools on the packaging
Mac. From the repository root, install them in a local virtual environment and
keep its executables on `PATH` for preflight and packaging:

```sh
python3 -m venv build/release-tools
build/release-tools/bin/python -m pip install -r scripts/release-requirements.txt
export PATH="$PWD/build/release-tools/bin:$PATH"
```

`dmgbuild` writes the DMG window layout directly, without Finder automation.
`scripts/dmg_settings.py` takes the background, icon positions and `/Applications`
drop link from the packaging inputs. The window geometry and background come from
`scripts/dmg_background.swift`. The DMG holds only the app and the
`/Applications` link.

Signing and notarization need two inputs on the packaging Mac:

- Exactly one **Developer ID Application** identity for the project's team in the
  login keychain. The script signs by its SHA-1, because two certificates of one
  team share a name.
- A `notarytool` keychain profile, `loomscreen-notary` by default (override with
  `NOTARY_PROFILE`). Create it once with an app-specific password from
  account.apple.com:

  ```sh
  xcrun notarytool store-credentials loomscreen-notary --apple-id <Apple ID> --team-id <Team ID>
  ```

The script checks both before it archives. Each SKU makes two notarization
submissions: the zipped app first (its ticket is stapled to the app, so a copy
dragged out of the DMG passes Gatekeeper offline), then the signed DMG. Stapling
changes the DMG, so it runs before the checksum and the Sparkle EdDSA signature.

Expected commands, Lite first so packaging order matches upload order:

```sh
scripts/release-app.sh --sku lite --version X.Y.Z --skip-checks \
  --notes-file build/release-notes/X.Y.Z.md
scripts/release-app.sh --sku pro  --version X.Y.Z --skip-checks \
  --notes-file build/release-notes/X.Y.Z.md
```

`--notes-file` is not optional in practice. Without it the appcast falls back to
the release-notes link alone, so Sparkle's update dialog says nothing about the
release while the GitHub page lists everything. Forgetting it on one SKU is easy
and silent — the packaging run still reports success.

`release-app.sh` re-runs the whole release-candidate gate for **each** SKU by
default, so an unqualified pair of commands runs it three times on one commit.
`--skip-checks` skips that repeat — use it only when the gate above already
passed on this exact commit, and say so in the release report. It does **not**
skip the per-SKU checks that matter: Sparkle helper re-signing and Team ID
alignment, signature verification, effective-entitlement inspection of the
signed app, bundle ID / display name / version fields, app and DMG
notarization and stapling, DMG mount, signature and Gatekeeper verification,
sha256, and appcast regeneration. Those are unconditional.

Validate the clean-clone tooling contract without building or signing:

```sh
scripts/release_contract_check.sh
scripts/release-app.sh --sku lite --version X.Y.Z --plan
scripts/release-app.sh --sku pro  --version X.Y.Z --plan
```

`--plan` performs no build and writes no artifact. Signing identities and
notarization credentials remain environment/machine inputs; they are not
stored in this repository.

The public Lite asset must be named `Loomscreen-X.Y.Z.dmg`. The Pro asset must
be named `Loomscreen-Pro-X.Y.Z.dmg`. Asset order does not affect the in-app
check: Sparkle reads the edition-specific appcast enclosure and compares
`CFBundleVersion`. Keep Lite first for a predictable download order.

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

The first line must be an H1 containing only the release version, for example
`# 0.9.0b2`, followed by a blank line. Use one version heading for the entire
bilingual document.

Three blocks, in this order: a download chooser, the three-section changelog,
and the system requirement. English set first,
then `---`, then the equivalent Simplified Chinese set. Link definitions go at
the very bottom of the file and are shared by both languages.

````markdown
# X.Y.Z

## Download

| Edition | Your Mac | Wallpapers |
| --- | --- | --- |
| [**Lite**][lite] | Intel or Apple Silicon | Video · Web |
| [**Pro**][pro] | Apple Silicon | Video · Web · **Wallpaper Engine scenes** |

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
- Changelog items come from what actually shipped in `git log <previous-tag>..HEAD`,
  picking what a user would notice. This is a changelog, not a summary of every
  commit, and not a rewording of `CHANGELOG.md`. Drop any section with nothing in it.
- Equivalent means equivalent: version numbers, command lines, paths, and the SKU
  names (Loomscreen / Loomscreen Pro) stay identical and untranslated, and neither
  language omits an item the other has. The Chinese headings are 新功能 / 改进 / Bug 修复.
- Still out: a marketing tagline or lead paragraph, and per-subsystem headings.
  The download block *is* wanted — but only in the table form above, never as
  prose paragraphs.

This file is the single source for both surfaces. `gh release create --notes-file`
renders the release page from it, and `scripts/generate-appcast.sh --notes-file`
lifts the three changelog sections — English half only, everything before the
`---` — into Sparkle's update dialog. The download table and the Chinese half
never reach the dialog: an updater that is already downloading
does not need a download table, and the pane is only 565x402. Write the notes
*before* packaging, because `release-app.sh --notes-file` passes them to the
appcast generator at package time; omitting the flag silently falls back to a
dialog carrying nothing but the release-notes link.

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

1. Download the Lite DMG from the release page on a clean Mac, so it arrives
   quarantined, and drag the app to `/Applications`.
2. Launch Loomscreen without any Terminal step. Gatekeeper may ask to confirm an
   app downloaded from the internet; it must not block it.
3. Confirm the menu bar app opens.
4. In **Settings -> About**, confirm the version is `X.Y.Z`.
5. Confirm **Check Now** talks to Sparkle (not an error, not a false
   “up to date” before the appcast is on `main`).

## Local artifact retention

Keep current stable and beta DMGs, checksums, xcarchives and matching dSYMs in
`build/release/`. Move superseded releases together into
`build/release/archive/YYYY-MM/`; retain their exact dSYMs for crash symbolication.
Record old/new paths when moving artifacts, without rewriting the historical
measurements or signatures in release receipts.

After verifying the retained DMG and confirming no app is using the staging path,
remove the disposable `staging-Loomscreen*` copies. Compiler/module caches can be
rebuilt; unique xcresults, traces, source snapshots and license provenance need
explicit retention or archival rather than blanket deletion. Keep the active
shader-toolchain inputs pinned by `WPEShaderCompiler/toolchain-inputs.sha256`.
