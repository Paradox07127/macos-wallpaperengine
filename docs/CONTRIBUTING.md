# Contributing

**English** · [简体中文](zh-Hans/CONTRIBUTING.md)

Issues and pull requests are welcome. Start with [Building](en/building.md)
for Xcode 27.0 and Metal Toolchain setup, and [Architecture](en/architecture.md)
for module ownership.

## Validate a change

1. Run the relevant behavior tests through `scripts/app_tests.sh suites <Suite>`.
2. Run the ordered repository gate:

   ```bash
   make verify
   ```

   This covers structure, localization, tooling contracts, changed-line lint,
   package tests and the app contract shard. It is not the complete app suite.
3. Run `scripts/app_tests.sh full` when broader app behavior is affected;
   before release, run `scripts/release_candidate_check.sh` for the full signed
   Pro suite, Pro/Lite link and archive matrix, and release checks.

Do not run Pro and Lite actions against the same DerivedData concurrently.
Keep app tests signed and check actual passed/failed/skipped counts. A runtime
invariant that must change needs a reason in the PR, not a quietly relaxed test.

## Formatting and localization

CI enforces changed-line formatting/lint through `make lint`, using
`.swiftformat`, `.swiftlint.yml` and the quality ratchets. It does not require
an unsolicited whole-repository reformat.

```bash
make lint BASE=main
scripts/format-changed.sh
```

The formatter helper operates on changed files, so review its diff and keep
unrelated formatting out of the PR. Quality exclusions are tracked by owner
and budget in `scripts/check_quality_exclusions.py`; advisory size warnings
are still debt even when the command exits successfully.

User-facing strings belong in the String Catalog for all five languages:
English, Simplified Chinese, Traditional Chinese, Japanese and Spanish.
UI changes use the existing [Core design system](../Packages/LiveWallpaperCore/DESIGN.md).
Update English and Simplified Chinese documentation together.

## Code and review boundaries

- Both app editions must build when changing SKU conditions. `LITE_BUILD` is an
  app-target flag; it does not propagate into Swift packages.
- Project/workspace files are maintainer-edited. Create source files on disk
  and identify any required target registration in the PR.
- Entitlement or Info.plist permission changes require explicit review of the
  affected feature and signed runtime boundary. Discuss new dependencies first.
- Rendering changes need targeted tests plus relevant capture/trace evidence;
  tests alone do not prove Windows parity. Pixel equality is not an acceptance
  criterion for RNG, fonts or floating-point output.
- Review notes and experimental plans stay out of public user docs. PRs should
  state the final behavior, validation and remaining limitations.

## Reporting bugs

Use **Settings → About → Report a Bug…** for a pre-filled report, review the
included diagnostics, and add reproduction steps. Or file a
[GitHub issue](https://github.com/Paradox07127/macos-wallpaperengine/issues)
with macOS version and Mac model. Security reports go through
[SECURITY.md](SECURITY.md), not the public tracker.
