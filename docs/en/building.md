# Build from source

**English** · [简体中文](../zh-Hans/building.md)

## Requirements

- macOS 14.6+ on an **Apple Silicon** Mac
- **Xcode 27.0**, matching shipping builds and the `xcode-27` CI runner.
  The UI also compiles against macOS 26 SDK APIs such as `glassEffect`; the
  macOS 14.6 deployment target does not mean a 14.x SDK can build the app.
- The **Metal Toolchain** component (Xcode 26 ships it as a separate download):
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
  Without it, compiling the `.metal` shaders fails with
  `cannot execute tool 'metal' due to missing Metal Toolchain`.

## Clone & open

```bash
git clone https://github.com/Paradox07127/macos-wallpaperengine.git
cd macos-wallpaperengine
open LiveWallpaper.xcodeproj
```

## Schemes

| Scheme | Edition | Notes |
|---|---|---|
| `LiveWallpaperLite` | Lite | Sets `LITE_BUILD`; Pro-only sources (`#if !LITE_BUILD`) are excluded. Produces `Loomscreen.app` (`com.loomscreen`). |
| `LiveWallpaper` | Pro | Full build. Produces `Loomscreen Pro.app` (`com.loomscreen.pro`). |

Pick a scheme and `⌘R`.

> **Don't build both schemes in parallel** — they share the same
> `XCBuildData/build.db`.

## Before opening a PR

Use the repository's ordered entry point:

```bash
make verify
```

It runs `fast` → `contracts` → `lint` → `test-packages` → `test-app`:
module/lifecycle/localization checks, release-tooling contracts, changed-line
lint, Core/ProWPE package tests, then the hardware-free app contract shard
with Pro and Lite hosts. It is **not** the complete Pro application suite.
Use `make help` for individual targets. Hosted CI uses the same make layers,
with the Pro-only hosted shard where a Lite signing identity is unavailable.

Before a release, run `scripts/release_candidate_check.sh`: it adds the full
signed Pro tests, Pro/Lite Debug/Release link matrix, archive smokes and
release/signing checks. Run the schemes sequentially when using shared build
storage; independent jobs require independent DerivedData directories.

The supported shipping and CI toolchain is Xcode 27.0. `make` defaults to
`/Applications/Xcode-beta.app/Contents/Developer`; set `DEVELOPER_DIR` when your
installation is elsewhere. See [Architecture](architecture.md) for the current
targets and packages; Video/Web tests live in the app target.

## Test workflows

Use the smallest gate that answers the current question, then run `make verify`
for integration and the complete release-candidate gate before release.

```bash
# Affected suites; each required suite must contain a passed test case.
scripts/app_tests.sh suites LocalizationCoverageTests EntitlementAuditTests

# Complete signed Pro app test target. The count floor catches gross zero/partial runs,
# but does not replace per-suite passed/skipped validation.
scripts/app_tests.sh full

# Repeat either command without rebuilding after a successful build on the same DerivedData.
scripts/app_tests.sh suites LocalizationCoverageTests --without-building
scripts/app_tests.sh full --without-building

# Hardware-free architecture and security shard used for fast PR feedback.
scripts/fast_app_contract_tests.sh

# Complete package, Pro, Lite, archive, signing, and entitlement gate.
scripts/release_candidate_check.sh
```

The app-test scripts keep verbose `xcodebuild` output in a raw log and use the
generated `.xcresult` for the terminal summary, non-zero test-count assertion,
required-suite presence, failures, and slowest-test list. Required suites must
contain at least one passed case; an allowed skip must be explicitly named with `--allow-skipped-suite`. Skipped tests do not count
toward the passed-test floor. Artifact paths are printed after every run. Set `DERIVED_DATA` to reuse a build location, and
set a fresh `RESULT_BUNDLE` path when an external job needs deterministic
artifact placement.

Swift Testing already runs independent tests concurrently in-process. Keep
shared mutable state isolated per test and use `.serialized` only for suites
that cannot be isolated; globally increasing Xcode worker processes can make
the app tests less reliable because several suites exercise process-wide state.
The fast contracts intentionally disable Xcode multi-worker parallelization;
those suites have filesystem and process-lifecycle contracts that are not
isolated between runner processes.

Do not add `CODE_SIGNING_ALLOWED=NO` to app test runs: removing entitlements
can silently skip the behavior under test. Select tests at suite granularity
and inspect the actual passed/failed/skipped results, not just the exit code.

## Packaging a release

See [`releasing.md`](releasing.md) for the maintainer-only Apple Development-signed DMG
packaging flow, preflight checklist, and current updater status.
