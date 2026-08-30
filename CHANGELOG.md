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

## [0.6.1] — 2026-08-30

### Added

- Weather effects read live conditions more faithfully: rain is rebuilt as
  streaks that lean with the wind, a Mist effect gives fog something to draw,
  and precipitation intensity now scales density. Each behavior has its own
  toggle on the display's weather card.
- Desktop overlays got liquid-glass cards, an Apple Music playhead with seek,
  and shared board history across displays.
- Onboarding was rebuilt around the real setup order, with appearance and
  widget styling steps.

### Changed

- "Apply to All Displays" for a weather overlay now copies the wind and
  intensity toggles too, matching what the confirmation promises.
- Switching the app language now reaches AppKit surfaces (file pickers, window
  titles) without a restart.
- Comment-heavy internals were compressed and dead code removed — about two
  thousand lines lighter with no behavior change.

### Fixed

- A malformed number, a junk array element, or a null animation track in a
  downloaded scene could crash the wallpaper agent at load, silently drop the
  valid parts around it, or drive one axis with another axis's animation. All
  parsing now saturates, keeps valid siblings, and holds track positions.
- The overlay master switch stops the Monitor and Now Playing panels again,
  and particles stay below app windows.
- A Now Playing overlay opened mid-song could draw transport controls that
  ignored clicks; a track ending under the pointer could leave the whole
  desktop swallowing clicks. The window's interactivity now follows the music.
- Skipping onboarding while a dropped folder was still importing no longer
  reopens the app on the display page after the import lands.
- Bug reports scrub wallpaper names before prefilling a GitHub issue: a local
  file's full path or a token in a Workshop title never leaves the machine.
- The system-wallpaper extension keeps a republish from dropping the old
  thumbnail and no longer reports success it didn't have.

## [0.6.0] — 2026-08-24

### Changed

- Updates are handled by Sparkle. The in-app dialog is gone; a scheduled check
  lights the menu bar button instead of interrupting a full-screen wallpaper,
  and the button opens Sparkle's own flow.
- Web wallpapers follow the frame-rate limit. It reached scene and video
  wallpapers only, so choosing 30 fps left `requestAnimationFrame` running at
  the display's rate.
- Less CPU per frame across scene wallpapers: uniforms, object matrices and
  render targets are now recomputed only when something actually changed.

### Fixed

- Critical memory pressure released scene resources alone. A video wallpaper
  held on to its player and decode pool, and a web wallpaper to its document,
  for the whole emergency.
- Turning off "Check for updates at launch" in 0.5.7 or earlier no longer comes
  back on. Sparkle keeps that choice under its own key and defaults to on, so
  the old setting is carried over once on first launch.
- The time-of-day tint kept the old hour's warmth after a time zone change.

## [0.5.7] — 2026-08-23

### Added

- "Show wallpaper in screenshots", in Settings → General. Off by default; turn
  it on to let screenshots, screen recording and screen sharing capture the
  wallpaper.
- The HTML security inspector now says why scripts are off, and names a loopback
  address as a local development server rather than an untrusted remote host.

### Changed

- Static frames no longer rebuild the render tree. Every layer and pass struct
  used to be copied each frame even when nothing was animating.

### Fixed

- An origin like `010.0.0.1` was judged private by its decimal spelling, but the
  resolver reads the leading zero as octal and dials the public 8.0.0.1. Private
  and loopback addresses are now decided the same way the connection is.
- An IPv6 origin lost its brackets when saved, so trusting one never persisted.
- A script that changed a layer's opacity froze that layer's color animation on
  its first frame.
- A pre-release left in the update cache could be offered to a stable install.

## [0.5.6] — 2026-08-22

### Added

- MetalFX upscaling, in Settings → General → Performance. A scene renders at
  0.75× or 0.5× of the display and MetalFX rebuilds the full image; heavy scenes
  measured 23–44% less GPU power. Off by default — on a light wallpaper it costs
  more than it saves.

### Changed

- Scenes start faster after a restart: the Metal shader translated from a scene's
  GLSL is now kept on disk instead of being retranslated every cold start.
- Video layers inside a scene decode at the display's pixel size instead of the
  file's, and how many decode at once is bounded by the Mac's memory.
- Less CPU per frame: render-target aliasing and uniform resolution are planned
  once at load rather than recomputed every frame.
- The Workshop grid no longer rebuilds every tile once a second, and previews
  decode off the main thread at tile size.
- Inspector sliders no longer write to disk, filters and the render session on
  every sample of a drag.
- Thumbnails in the Library, Workshop, history and system-wallpaper lists share
  one title band, so the same card looks the same everywhere.
- A row's title and subtitle no longer scroll on hover; long text truncates with
  the full string in the tooltip.
- The SteamCMD setup check remembers a passing result and re-probes only when the
  binary it approved has changed.

### Fixed

- Scrolling a scene's settings could stutter badly. A property authored in steps
  of 0.001 over a 0–300 range asked SwiftUI for 300,000 slider stops; the count is
  now capped where the cost stops growing.
- Turning MetalFX upscaling off mid-session left resources sized for the old
  resolution behind.
- A scene that failed to load left its partially built state in place.
- GIF previews kept decoding inside a collapsed inspector, and a dropped animated
  texture left its prefetch running.
- Log messages below the current level still built their strings.

## [0.5.5] — 2026-08-20

### Added

- A Now Playing layer for the desktop overlay: borderless artwork-and-type
  rendering of the current Spotify or Apple Music track in three styles
  (Poster, Vinyl, Aurora), with cover-derived accent colors, a progress line
  when the player reports one, and audio-reactive visuals when Audio Response
  is enabled. It listens to the players' own broadcasts and disappears entirely
  while nothing is playing.
- Music is its own overlay page, switched on and layered independently of the
  Monitor board, positioned by nine-point anchors or by dragging it in the
  preview, and customizable throughout: accent source and opacity, typography
  and alignment, which fields appear, artwork shape and size, and five
  audio-reactive effects (pulse, chromatic split, shake, particles, beat
  ripples) driven by real beat detection.
- Transport controls and a draggable progress bar on the Now Playing layer,
  appearing on hover. Controlling a player asks for macOS Automation access the
  first time; declining just leaves the buttons inert.
- Optional synced lyrics on the Now Playing layer, fetched from the public
  LRCLIB service. Spotify reports a playback position, so its lyrics follow the
  song line by line; Apple Music broadcasts no position, so its lyrics are shown
  from the top without a moving highlight.
- Every wallpaper type previews on one stage: video, web and scene now share the
  same centered, correctly proportioned card and the same control placement.
- Searching the Workshop keeps the sort you picked instead of forcing Relevance,
  and clearing the search returns to the sort you were on.
- Remove All in the System Wallpaper library, for taking every published copy
  back in one step.
- An opt-out for the launch-time update check, in Settings → General. It was
  always on before; the About page's manual check is unaffected.

### Fixed

- On a Mac with one display permanently asleep — a closed lid, a switched-off
  external panel — the away-detection safety net never engaged, so a dropped
  wake or unlock notification could still leave wallpapers suspended. Presence
  now clears as soon as any display is awake.
- Waking a scene twice in quick succession could cancel the load still in
  flight and strand the scene on its still frame until the next manual play.
- A manually paused video or web wallpaper released its resources about
  20 seconds later than a paused scene did. All three now release at the same
  five-minute mark.
- Scene videos stuttered at the loop point on the legacy playback path, and a
  silent audio track in a cached video delayed every loop.
- Republishing a system wallpaper that then failed left the old video replaced
  and the library inconsistent with the error it reported; the previous copy is
  now restored. A library index that exists but cannot be read is refused
  instead of being rewritten from scratch, and clearing the library no longer
  reports success when a file could not be deleted.
- With two displays on two system wallpapers, the second one could be treated as
  idle and offered for deletion while it was still on screen.
- Audio-strip scratch files left behind by a force-quit were invisible to the
  video cache's size accounting and never reclaimed.

## [0.5.4] — 2026-08-19

Videos no longer need Loomscreen running: a system wallpaper extension hands
them to macOS itself, so they keep playing with the app closed and the lock
screen changes with them. The rest of the release is playback and policy
correctness — most of it found by reviewing everything that landed since
0.5.3 rather than by reports.

### Added

- **System Wallpaper.** Hand a video to macOS as a native wallpaper source.
  It plays with Loomscreen closed, on the desktop and on the lock screen,
  and appears in System Settings alongside Apple's own wallpapers. Videos
  come from a file, a library bookmark, or a Workshop package. A switch
  chooses between playing continuously and easing to a still once you are
  back at the desktop, the way Apple's own video wallpapers behave. Needs
  macOS 26 or later; on earlier versions Loomscreen plays wallpapers itself,
  which requires the app to be running.

### Fixed

- The play button could strand a suspended wallpaper instead of resuming it.
- Video playback did not resume after a buffer underrun.
- Videos on volumes Foundation will not memory-map — external drives, network
  shares — failed to play. They are streamed now instead of being read whole.
- Opening the settings window reflowed every component in it. The saved
  window size was restored only after the view hierarchy had already been
  laid out at the default size, so everything was placed twice.
- A buffering video was reported as "paused by the system", which also
  reversed what the play button did while the stall lasted.
- Serious thermal pressure and memory warnings stopped affecting video
  wallpapers. The throttle tier introduced for scenes has no consumer for
  video, which has no frame-rate control to shed load with, so video
  suspends under that pressure again.
- A dropped display-wake or unlock notification could leave every wallpaper
  suspended for the rest of the session, unreachable by the play button.

### Changed

- User play intent is held in one state machine per screen instead of a copy
  inside each wallpaper runtime.
- Chip-sized controls — status chips, type badges, filter chips — render a
  flat fill instead of Liquid Glass. The material is now reserved for
  surfaces that genuinely float above content, such as badges layered over a
  thumbnail.

## [0.5.3] — 2026-08-17

Follow-up to the hibernation work in 0.5.2. Each of the three wallpaper
runtimes had grown its own copy of the absence countdown and the
cover-then-release sequence, and the copies had drifted apart; this release
collapses them onto one implementation and fixes three cases where a display
could stop hibernating for the rest of the session. As in the previous window
a large share of the work was Pro-only (Wallpaper Engine scenes), which this
file does not cover.

### Fixed

- A display could stop hibernating for the rest of the session. Two of the
  three runtimes treated a transient blocker — a rebuild still in flight, so
  there is nothing to release yet — as "no longer applicable" and dropped the
  countdown. Eligibility is pushed on policy changes rather than polled, so a
  dropped countdown was never re-armed and the wallpaper stayed fully resident.
- A suspend arriving while a wallpaper was still rebuilding left it in a phase
  that no eligibility check would arm from, with the same result: that display
  never hibernated again.
- Scene render states compared unequal to themselves. The hand-written equality
  predated one of the states and never learned it, so a refresh that diffs the
  previous state against the next one saw a change that had not happened.

### Changed

- Video, HTML, and scene wallpapers now share one absence countdown and one
  cover-then-release phase machine instead of three drifting copies. Ordering
  is the point of that machine: the cover has to be on screen before the live
  document or player is released, or the desktop flashes blank.

## [0.5.2] — 2026-08-17

A memory and power pass over the wallpaper runtimes, plus one long-standing
bug that made inline HTML wallpapers render as a blank page. As in the previous
window a large share of the work was Pro-only (Wallpaper Engine scenes and the
system-audio spectrum), which this file does not cover.

### Fixed

- Inline HTML sources rendered as an empty document. `loadHTMLString` reaches
  the navigation policy as an `about:blank` navigation, which the policy
  cancelled; the resulting cancellation was then swallowed as a routine
  "navigation cancelled" error, so the page stayed blank with nothing logged.
- The monitor board drew fabricated history for a widget added to a board that
  was already running. Metric groups no placed widget reads are not sampled at
  all, and the unsampled slot was recorded as a literal zero — indistinguishable
  from a real idle reading once it was in the series. Adding a CPU widget to a
  board that had been showing only network could therefore draw several minutes
  of "CPU at 0%" that never happened.
- A memory-pressure notification that cleared could be overtaken by the
  critical one that preceded it, re-arming an emergency release cycle after the
  emergency was over.

### Changed

- A video wallpaper that has been out of sight for twenty seconds is replaced by
  a still frame while its player, decode pool, and in-memory mapping are
  released. It is rebuilt on the way back; the still frame is held until the
  rebuilt player actually has a picture, and dropped on a deadline if it never
  does. (Playback itself still decodes through `AVPlayerLayer` unchanged — the
  saving is the release, not the pixel format.)
- HTML wallpapers suspend more of what they are actually running. The lifecycle
  hooks now reach subframes (embedded players and ad frames own timers and
  canvases the main frame cannot touch), `Worker` instances are managed without
  the page having to opt in, and a wallpaper that has been out of sight for
  twenty seconds has its document dropped behind a snapshot of its last frame.
- WebGL contexts no longer have multisampling forced on when the page explicitly
  asked for `antialias: false`. The default stays on for pages that do not
  specify it.

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
