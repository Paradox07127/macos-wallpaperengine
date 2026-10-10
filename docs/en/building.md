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

Ordinary Pro app changes use targeted suites or `make test-app-hosted`.
Use `make test-app` when Lite/Pro behavior is affected. For cross-module
integration, the ordered entry point is:

```bash
make verify
```

It runs `fast` → `contracts` → `lint` → `test-packages` → `test-app` →
`test-wpe-metal`: module/lifecycle/localization checks, release-tooling contracts,
changed-line lint, Core/ProWPE package tests, the hardware-free app contract shard
with Pro and Lite hosts, then signed WPE and transition Metal suites with GPU
validation enabled. The Metal stage requires the local graphics/signing environment;
it is **not** a hardware-free check or the complete Pro application suite.
Use `make help` for individual targets. Hosted CI runs selected make layers and
uses the Pro-only hosted shard where a Lite signing identity is unavailable;
it does not replace the local Metal gate.

Before a release, run `scripts/release_candidate_check.sh`: it adds the full
signed Pro tests, Pro/Lite Debug/Release link matrix, archive smokes and
release/signing checks. Run the schemes sequentially when using shared build
storage; independent jobs require independent DerivedData directories.

The supported shipping and CI toolchain is Xcode 27.0. `make` defaults to
`/Applications/Xcode.app/Contents/Developer`; set `DEVELOPER_DIR` when your
installation is elsewhere. See [Architecture](architecture.md) for the current
targets and packages; Video/Web tests live in the app target.

## Test workflows

Use the smallest gate that answers the current question. Run `make verify`
when integration risk justifies it, and the complete release-candidate gate before release.

```bash
# Affected suites; every required case and parameterized run must pass.
scripts/app_tests.sh suites LocalizationCoverageTests EntitlementAuditTests

# Complete signed Pro app test target, with case-level checks for required suites.
scripts/app_tests.sh full

# Explicit lanes for the full Pro target and local window/input contracts.
make test-app-full
make test-app-interaction

# Repeat either command without rebuilding after a successful build on the same DerivedData.
scripts/app_tests.sh suites LocalizationCoverageTests --without-building
scripts/app_tests.sh full --without-building

# Small daily data/security/apply/session shard used for PR feedback.
scripts/fast_app_contract_tests.sh

# Complete package, Pro, Lite, archive, signing, and entitlement gate.
scripts/release_candidate_check.sh
```

The app-test scripts keep verbose `xcodebuild` output in a raw log and use the
generated `.xcresult` for the terminal summary, non-zero test-count assertion,
required-suite presence, failures, and slowest-test list. Every case/run in a required
suite must pass. Environmental exceptions name exact cases and reasons in
`scripts/app_test_skip_policy.json`; a passed sibling cannot cover a skipped or
unknown result. At least one test must execute; there is no arbitrary total-count
ratchet. Artifact paths are printed after every run. Set `DERIVED_DATA` to reuse a build location, and
set a fresh `RESULT_BUNDLE` path when an external job needs deterministic
artifact placement.

Case validation reads the existing result tree once. It does not launch additional
tests or require one runner invocation per case; suite selection determines run time.

The daily app shard is intentionally small: data persistence/import, trust and
filesystem boundaries, wallpaper apply/session ownership, playback intent,
automation and download cancellation. Layout/copy checks, feature-specific
parser/rendering cases and stress tests run when that area changes, or in the
full target. A useful regression test does not automatically belong in every PR.
Do not add new admission frameworks or count ratchets to maintain this distinction;
edit the existing shard only when a critical behavior needs a guard.

Narrow static guards for an independent regression may remain where behavioral tests
do not cover that boundary. Check the actual replacement before removing a source
assertion, ordering rule, compatibility value or resource safety limit.

Package gates read Swift Testing's xUnit case results, rejecting missing, empty,
failed or skipped runs. A console summary can include skipped tests in its passing
total, so that text is not execution evidence. Required CI jobs retain their result
bundles/reports and raw logs. `make verify` remains a selected integration gate;
local window/input tests, the full Pro target and release validation are explicit
separate commands. Make targets execute sequentially even when invoked with `-j`.

Keep tests that protect an observable product contract: persisted settings and
migrations, cancellation and lifecycle ownership, trust boundaries, real input
delivery, or renderer output with an independent expected result. Before adding a
test, identify the regression it would catch and whether an existing test can cover
it. Prefer one effective guard per behavior. A test of a private test-only decoder,
two copies of a constant list, or exact source spelling does not establish app
behavior. Static source checks can enforce forbidden dependencies or unsafe APIs;
they do not prove that a control, callback or renderer works. Corpus capture and
diagnostic export are evidence tools, and their successful execution is not a
product regression verdict. For important guards, deliberately break the relevant
behavior and verify a meaningful failure before restoring it. Counts and coverage
alone are not acceptance criteria.

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
