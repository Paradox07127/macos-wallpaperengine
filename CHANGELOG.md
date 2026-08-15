# Changelog

All notable changes to **Loomscreen** (the open-source Lite edition) are
tracked here. Format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

While Loomscreen is on the `0.x` line the public surface is considered
unstable — any `0.y` → `0.(y+1)` bump may introduce breaking changes to
the configuration schema, UI layout, or feature gating. A `1.0.0` tag
will be cut once the surface has stabilized through real-world use.

Pro-edition (`Loomscreen Pro.app`) release notes live separately and are
not covered by this file.

## [0.5.1] — 2026-08-14

Promotes `0.5.1-beta`. Everything below landed after that pre-release; the
entry for it is kept underneath rather than rewritten. Most of the work in
this window was again Pro-only (Wallpaper Engine scenes and the Steam Workshop
setup), which this file does not cover.

### Changed

- The monitor board's refresh interval now reaches every stage behind it.
  Samples were already taken at the chosen rate, but delivery stayed pinned at
  once per second, so sub-second settings spent power on readings nothing drew.
  The GPU's own sampling period was also computed against a fixed two-second
  tick, which meant a board asking for a six-second GPU sample got one every
  three seconds — and every 1.5 seconds at the fastest setting.
- The CPU widget's trend is now windowed by wall clock instead of by sample
  count, so a 60-second sparkline covers 60 seconds at any refresh rate. At the
  five-second setting it had been showing five minutes.
- Expensive sampling now follows each widget's section toggles rather than only
  its kind. Switching off a sensor row or a process list stops the SMC reads and
  the process-table walk instead of just hiding the result.

### Removed

- `gridColumns` is gone from the board configuration schema. Boards have laid
  out free-form against the display's cell pitch for some time, and existing
  configurations decode unchanged without it.

## [0.5.1-beta] — 2026-08-14

`0.4.x` and `0.5.0` shipped without their own entries here. This one covers
what changed in the Lite build between `0.3.0` and `0.5.1-beta` rather than
reconstructing per-version notes after the fact. Most of the work in that window
landed in the Pro-only Wallpaper Engine and Steam Workshop stacks, which this
file does not cover.

### Changed

- The release DMG now opens as a laid-out window — background image, positioned
  app icon, and `/Applications` alias — instead of a bare volume listing.
- Documentation moved to `docs/en/` with a Simplified Chinese counterpart under
  `docs/zh-Hans/`, and gained contributing and security pages.

### Removed

- Dead string-catalog entries and a large amount of unreferenced code, with no
  intended change in behavior.

## [0.3.0] — 2026-07-25

### Changed
- Wallpaper replacement is now transactional. A new wallpaper is prepared
  off-screen and only swaps in once it has produced a real first frame, so
  switching no longer shows a gap where the old wallpaper is already gone. If
  preparation fails or times out, the visible wallpaper and its stored
  configuration are left untouched instead of being torn down.
- Display geometry now comes from a single process-wide observer. Each video
  player previously registered its own screen observer plus a 30-second poll;
  both are gone, and every player receives identical geometry updates.
- Automation no longer keeps a timer alive when nothing is scheduled. Display
  sleep, screen lock, and system sleep stop automation entirely; waking starts a
  fresh playlist deadline and reconciles the active schedule exactly once.
- HTML wallpapers now suspend media playback, timers, and animation while they
  are hidden or suspended, instead of continuing to run in the background.
  Pages that cannot be suspended cooperatively are handled explicitly.
- Offscreen HTML thumbnails now go through the same trust policy and typed
  configuration as the live runtime and use ephemeral storage, so generating a
  preview no longer leaves persistent website data behind.
- Workshop preview assets are now held in bounded caches with cost and count
  eviction rather than growing for the lifetime of the process.
- Particle effects on a video wallpaper now freeze while the session is
  suspended by policy or offscreen, and resume without losing state. Manually
  pausing a video keeps its previous particle behavior.
- Weather location requests now coalesce: concurrent resolves share one Core
  Location request and a single system permission prompt. Only a genuinely
  denied or restricted authorization is reported as a permission failure.

### Fixed
- A frame-rate throttle change made while an HTML wallpaper was suspended is now
  applied when it resumes, instead of being lost.
- Display-link rebuild and terminal stop are now ordered, so a late rebuild
  after teardown can no longer leave a live link behind during display
  reconfiguration. *(Pro renderer; no runtime effect in the Lite SKU.)*
- Additional WPE scene-rendering fixes landed in the shared codebase — frame
  admission and GPU resource lifetime, per-frame autorelease behavior on the
  render thread, and particle sprite aspect handling for sheet-backed textures.
  These remain Pro-only at runtime in the Lite SKU.
- System audio capture now runs only when it is enabled *and* at least one live
  wallpaper actually needs spectrum data. *(Pro renderer; no runtime effect in
  the Lite SKU.)*

## [0.2.4] — 2026-07-07

### Changed
- Content-Security-Policy enforcement for folder and WPE web wallpapers is now
  governed entirely by its opt-in toggle. With the toggle off (the default),
  scheme responses no longer attach the enforced CSP header, so wallpapers that
  legitimately need iframes or external frames render correctly; the WebKit
  sandbox and custom-scheme isolation still apply. Enable the toggle to restore
  the strict header.
- Diagnostic bug reports now redact a broader set of identifiers — Steam IDs,
  IPv4/IPv6 addresses (including compressed forms), local hostnames, and Steam
  account/persona names — before they leave the app.

### Fixed
- Internal settings and typography refactors (the General settings screen was
  split into per-section files; assorted inline fonts moved onto the design
  tokens) with no intended visual change.
- Additional WPE scene-rendering fixes landed in the shared codebase — off-frame
  script evaluation, typed shader dispatch, and attachment/geometry handling —
  which remain Pro-only at runtime in the Lite SKU.

## [0.2.3] — 2026-07-04

### Changed
- Settings and shortcut surfaces were tightened for clearer navigation,
  action labels, and destructive-action presentation.
- Localization catalogs were refreshed and coverage checks were updated for
  the current UI strings.
- Release documentation now calls out the manual DMG publishing path and the
  current updater boundary: public builds still use GitHub Releases checks and
  manual download/replace updates.

### Fixed
- Additional WPE scene-rendering, puppet-model, particle, and render-graph
  stability fixes landed for the shared codebase. These remain Pro-only at
  runtime in the Lite SKU.
- Workshop and engine-assets maintenance paths were hardened, including
  SteamCMD diagnostics and installed-item presentation.

## [0.2.2] — 2026-07-01

### Added
- Scene diagnostics are now included in release bug reports to improve triage for
  scene rendering issues.
- Release documentation structure was expanded (`docs/README.md`,
  `docs/screenshots.md`, `docs/quick-start.md`, `docs/troubleshooting.md`) for
  easier onboarding and publishing prep.

### Changed
- Scene and settings detail surfaces were refined for smoother workflow and clearer
  status feedback.
- Runtime session and resource handling were improved in scene/playlist paths to
  reduce stale-state issues.

### Fixed
- Multiple WPE scene-path performance and stability fixes, including rendering
  pipeline and cache behavior.
- Better diagnostics around scene project metadata parsing, custom shader paths, and
  multi-root resource resolution.
- Additional edge-case hardening for HTML playlist/session handling.

## [0.2.1] — 2026-06-29

Maintenance release. Most of this cycle's work is in the Pro-only Metal scene
renderer (large performance and GPU-memory wins) and is not listed here; the
Lite-facing changes are below.

### Added
- HTML wallpapers now transcode Ogg audio to AAC so tracks WebKit can't play
  natively still play.

### Changed
- Onboarding, scene, and settings refinements; assorted UI polish.

### Fixed
- Security-scoped bookmark resolution now routes through a single resolver that
  always observes the staleness flag, reducing "re-grant access after restart"
  cases for imported folders and authorized directories.
- Cleared remaining compiler warnings; the in-app updater resolves the Lite DMG
  on a unified release; full ja / zh-Hans / zh-Hant coverage maintained.

## [0.2.0] — 2026-06-27

App-wide UI overhaul plus a batch of stability and localization fixes. The
WPE Metal scene renderer is Pro-only (`#if !LITE_BUILD`), so its work is not
listed here.

### Added
- Design-token foundation for the app UI: a Typography scale plus semantic
  Color / Status tokens, documented in a `DESIGN.md`, with app and shared-
  package text migrated onto the tokens.
- Native Xcode-style detail inspector (`.inspector()` / AppKit split bridge)
  with a toolbar toggle that compresses the detail instead of growing the
  window.
- Scene tab as a lightweight quick-apply surface with a "Browse all"
  Workshop entry; type glyphs on installed / scene cards.
- Clearer General and Workshop settings copy with info tooltips.

### Changed
- App-wide UI unification: slimmer sidebar with status-colored row icons, a
  compact inspector, one unified glass gallery card, circular/larger header
  icon buttons, and `SettingRow` adopted across settings panels.
- Workshop online browse: debounced auto-search (Search button removed),
  full-height resizable detail panel, and the tab switcher / panel toggle
  moved into the window toolbar.
- Freeing disk space now deletes downloaded Workshop files outright instead
  of moving them to the Trash.

### Fixed
- Inspector expand/collapse animation and layout glitches (panel stays
  mounted, window no longer jumps, sidebar width pinned).
- Scene detail now scrolls at small window heights.
- Destructive buttons drop the red plate behind red text; bookmark action
  only shows when there is a project to bookmark.
- String-catalog sync: every entry translated, stale entries dropped, and
  the localization coverage suite is fully green again.

## [0.1.0] — 2026-05-25

First public release. Open-source Lite edition of the LiveWallpaper
codebase, distributed via GitHub Releases.

### Added
- Loomscreen identity for the Lite target: dedicated `Info.plist`, bundle id
  `com.loomscreen`, UTI `com.loomscreen.config` (`.loomscreen` files), and a
  Loomscreen-only display name so it coexists with the Pro app on the same
  Mac without LaunchServices collisions.
- In-app update checker: single launch-time GitHub Releases lookup throttled
  to 12 h, manual "Check Now" button from the About panel, "Skip this
  version" persistence, hostile-response defenses (URL allow-list, response
  size cap, content-type guard, generic error surface).
- ad-hoc release packaging script (`scripts/release-loomscreen.sh`) and the
  matching GitHub Actions workflow that publishes a DMG + SHA-256 on every
  `loomscreen-v*.*.*` tag push.
- MIT `LICENSE`, this `CHANGELOG`, and the Loomscreen sections of the
  `README` (download / first-launch quarantine command / Pro-vs-Lite
  feature matrix / troubleshooting).

### Changed
- `ConfigurationBundle.contentType` now resolves the host SKU's UTI from
  `Bundle.main.bundleIdentifier`, with SKU-prefix-guarded historical
  fallbacks so a Pro test runner never accidentally resolves a Lite UTI when
  both apps are registered, and vice versa.
- `MenuBarContent` `OSSignposter` subsystem and the menubar / About hero
  product label are now bundle-derived (`BundleIdentity.productDisplayName`),
  so Loomscreen renders "Loomscreen" in every locale instead of inheriting
  the Pro brand label via the shared `InfoPlist.xcstrings`.

### Fixed
- `InfoPlist.xcstrings` no longer localizes `CFBundleDisplayName` /
  `CFBundleName` to "LiveWallpaper" for every locale, which used to
  override Loomscreen's hard-coded display name at runtime.
