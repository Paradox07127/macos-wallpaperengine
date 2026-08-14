# Contributing

**English** · [简体中文](zh-Hans/CONTRIBUTING.md)

Issues and pull requests are welcome. This page is the short version; the
details live in [building.md](en/building.md).

## Before you open a PR

1. Read [building.md](en/building.md) for the toolchain requirements — macOS 14.6+
   on Apple Silicon, Xcode 26+, and the separately downloaded Metal Toolchain.
2. Run the release-candidate gate:

   ```bash
   scripts/release_candidate_check.sh
   ```

   It runs the Swift package tests, then the signed Pro app tests, then the Lite
   build, in that order. Do not run the Pro and Lite halves in parallel — they
   share one `XCBuildData/build.db`.
3. If your change has to diverge from a runtime invariant a suite enforces
   (localization coverage, particle and render behavior, entitlements), say so
   in the PR description rather than relaxing the test quietly.

## Formatting

Neither SwiftFormat nor SwiftLint is enforced in CI — `.swiftformat` and
`.swiftlint.yml` describe the house style, they don't gate your PR.

**Do not run SwiftFormat over the whole repository.** This codebase is not
formatter-clean, so a full pass rewrites thousands of lines, destroys `git blame`,
and collides with in-flight refactors. Format only what you touched:

```bash
scripts/format-changed.sh          # files changed vs HEAD, staged, and untracked
scripts/format-changed.sh main     # files changed vs another base
```

The god-files listed in `.swiftformat`'s `--exclude` are skipped automatically;
that list is kept in sync with `.swiftlint.yml` by
`scripts/check_quality_exclusions.py`.

## Things that will be asked of every PR

- **Both editions build.** Anything touching `#if !LITE_BUILD` has to compile
  under both the `LiveWallpaper` and `LiveWallpaperLite` schemes. A green single
  scheme proves nothing about the other one.
- **Strings are localized.** User-facing text goes through the string catalog in
  all four shipped languages (English, Japanese, Simplified Chinese, Traditional
  Chinese). There is no escape hatch for "just this one string".
- **Docs stay in sync.** If you change behavior described in `docs/`, update the
  English page *and* its `zh-Hans/` counterpart in the same PR.
- **Rendering claims need evidence.** "This fixes the renderer" has to come with
  a capture, a dump, or a test — not a reading of the code. Pixel-level diffs are
  explicitly not an acceptance criterion here (RNG, font rasterization, and
  floating-point differences make them noise).

## Scope

- `LiveWallpaper.xcodeproj` and its `.pbxproj` are maintainer-edited. Add new
  source files to disk and mention them in the PR; don't hand-edit the project
  file.
- `.entitlements` files and Info.plist permission keys change only with an
  explicit reason in the PR description.
- New Swift Package dependencies need a discussion first.

## Reporting bugs

Use **Settings → About → Report a Bug…** in the app — it pre-fills the
diagnostics an issue needs. Otherwise open a
[GitHub issue](https://github.com/Paradox07127/macos-wallpaperengine/issues)
with your macOS version, Mac model, and reproduction steps.

Security issues go through [SECURITY.md](SECURITY.md) instead, not the public
tracker.
