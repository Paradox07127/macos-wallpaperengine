# Feature Guide

**English** · [简体中文](../zh-Hans/features.md)

The authoritative map from user-facing features to their implementation. For a
task-oriented walkthrough, use [quick-start.md](quick-start.md) instead.

Authoritative capability gate: [`ProductCapabilities.swift`](../../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## 0) App surfaces

- **Menu bar** (`LiveWallpaper/Views/MenuBarContent.swift`)
  - Quick-add wallpaper, global on/off toggle.
  - **Update** button, left of the toggle, only while a newer release is available.
  - Per-display rows: status, play/pause, prev/next (playlist mode), volume.
  - Live usage strip (CPU / GPU / RAM / thermal pressure).
  - Manage, General Settings, reload-all, quit.
- **Settings window** (`LiveWallpaper/Views/ContentView.swift`, `LiveWallpaper/Views/Settings/Navigation.swift`)
  - Sidebar: per-display pages, Bookmarks, Schemes, Apple Aerials, Steam Workshop (Pro).
  - Settings tabs — availability varies by SKU:

| Tab | Edition | Contents |
|---|---|---|
| General | both | Language, start at login, lock-screen frame capture, Dock visibility |
| Display Defaults | both | Default mute/volume, frame cap, fit mode, color space, web interaction |
| Performance | both | Pause rules, app exceptions, RAM preload budget; **Pro adds** adaptive frame rate & per-display render threads |
| Audio Response | Pro | System audio capture for audio-reactive scenes |
| Weather | both | Off / system location / manual location for weather-reactive overlays |
| Shortcuts | both | Master switch + seven bindable global shortcuts |
| Storage | Pro | Downloaded projects, engine assets, caches |
| Backup & Restore | both | `.lwconfig` export / import |
| Workshop | Pro | API key, SteamCMD doctor, engine-asset updates, content filters |
| Advanced | both | Diagnostics export, bug report, log folder |
| About | both | Version, links, Welcome Tour, update banner |

## 1) Wallpaper types

`WallpaperType` (`Packages/LiveWallpaperCore/.../Schema/WallpaperType.swift`) has
three cases — video, HTML, scene. Apple Aerials are applied as video sources.

### Video (both editions)

- Formats: `mp4`, `m4v`, `mov`, `avi` (`Schema/../Persistence/ResourceUtilities.swift`).
- Fit modes Fill / Fit / Stretch; frame-rate caps 15/24/30/60/unlimited.
- Color spaces: auto, sRGB, Display P3, Rec. 2020 HDR, force-SDR (`Schema/VideoColorSpace.swift`).
- Per-display playback or a single video spanned across all displays (`Schema/VideoDisplayMode.swift`).
- RAM preload budget per screen for smooth looping.

### Web (both editions)

`Schema/HTMLConfig.swift` — per-display: JavaScript toggle, mouse interaction,
tracker blocking, custom CSS, mute/volume, auto-refresh interval,
scale/pan/rotate transforms, Retina physical-pixel layout, ephemeral storage
(forced for Workshop imports), CSP enforcement, aggressive suspend.

### Apple Aerials (both editions)

`LiveWallpaper/Infrastructure/Platform/AppleAerialsLibrary.swift` scans the
aerial videos macOS has already downloaded; browse, search, and apply from the
sidebar library.

### Wallpaper Engine scenes (Pro)

- Native Metal renderer for WPE `scene.pkg` projects: layered scenes, particle systems, puppet-warp animation, SceneScript, text layers, audio-reactive and cursor effects. GLSL effects inside a scene are transpiled to Metal at load (`LiveWallpaper/Runtime/Metal/WPEShaderTranspiler*.swift`) — shaders are part of scene rendering, not a separate wallpaper type.
- Sources: local project folders (read in place) or Steam Workshop downloads.
- Scene-specific controls: fit mode incl. Center, cursor parallax, click interaction.
- Projects requiring Windows executables are skipped on import.

#### Scene presets (Pro)

A preset is a named set of `project.json` property values bound to one base
wallpaper (`Schema/ScenePreset.swift`). Downloaded Workshop preset items and
"save my current values" are the *same* object, which is what lets a downloaded
preset be renamed, re-saved, and exported like a local one.

- **Applied as a layer, never baked in**: scene defaults → preset → your
  per-display increment. "Reset to preset" is therefore just dropping the
  increment.
- Presets also carry Wallpaper Engine's own per-wallpaper application settings,
  which are *not* `project.json` properties and so are not in the wallpaper's
  schema:
  - **Colour correction** (`wec_e` enable flag plus brightness / contrast /
    saturation / hue on a 0–100 scale, 50 neutral) becomes a full-frame post
    pass, skipped entirely when the values are neutral —
    `Schema/WPEEngineColorCorrection.swift`,
    `Runtime/Metal/WPEMetalRenderExecutor+Present.swift`. The neutral point and
    enable flag were established from real published presets; the transfer
    curves are matched to the app's own video colour controls rather than being
    bit-exact with Wallpaper Engine.
  - **Volume** (0–100) becomes a gain that *multiplies* your master volume
    instead of replacing it — `Schema/WPEEngineAudioSettings.swift`.

  Both read the preset snapshot rather than the layered map, so a wallpaper that
  declares its own property named `volume` cannot drive the engine setting.
- UI: the **Preset** row in the scene settings card
  (`LiveWallpaper/Views/ScreenDetail/ScenePresetBar.swift`) — a picker split
  into *Saved by you* and *From the Workshop*, plus save / rename / delete.
  Workshop wallpaper pages list the presets published for that wallpaper
  (`LiveWallpaper/Views/Workshop/DetailPresetsSection.swift`); listing
  them needs a Steam Web API key, downloading one needs SteamCMD.

## 2) Playback & automation

- **Playlists** (`LiveWallpaper/Views/Playlist/PlaylistSection.swift`, `LiveWallpaper/Policies/PlaylistPolicy.swift`) — drag-reorder, shuffle, 1–1440 min rotation, apply to one or all displays.
- **Schedule** (`LiveWallpaper/Views/ScheduleSection/`, `LiveWallpaper/Policies/SchedulePolicy.swift`) — time slots with presets, conflict detection, fallback to the primary wallpaper.
- **Coordinator** (`LiveWallpaper/Policies/WallpaperAutomationCoordinator.swift`) — one 60-second tick, running only while some display actually has automation; stops entirely during lock/sleep and reconciles once on wake.
- **Bookmarks** (`Schema/WallpaperBookmark.swift`, `LiveWallpaper/App/ScreenManager+Bookmarks.swift`) — a favourite wallpaper and nothing else. Applying one swaps the content and leaves every setting on the target display untouched.
- **Schemes** (`Schema/ScreenScheme.swift`, `LiveWallpaper/App/ScreenManager+Schemes.swift`) — one display's complete setup: wallpaper, overlay (Monitor board and Now Playing layer) and every playback, effect, playlist and schedule setting. Applying one replaces the whole setup on the target display, behind a confirmation. Widget and overlay positions are stored normalized, so a scheme captured on one display lands correctly on a differently-sized one. Local archive only — a scheme references media through per-machine security-scoped bookmarks, so it is not portable between machines.
- **Import routing** (`LiveWallpaper/Infrastructure/Assets/WallpaperImportRouter.swift`) — one classifier behind the toolbar picker, drag & drop, and onboarding: video / scene project / scene library / html / unsupported.

## 3) Overlays

All overlays are renderer-independent — they stack on video, web, and scene
wallpapers alike.

- **Particles** (`Schema/ParticleEffect.swift`) — Snow, Rain, Bokeh, Fireflies, Dust, Stars, Leaves, Sakura.
- **Weather-reactive** (`LiveWallpaper/Runtime/WeatherReactiveService.swift`) — hourly Open-Meteo conditions map to particle effects and video adjustments (saturation, brightness, temperature…). Location: off / system / manual.
- **Monitor board** (`LiveWallpaper/Monitor/`) — per-display, desktop layer (click-through) or always-on-top. Widgets: CPU, Memory, GPU, Network, Disk, Power, Processes, Agent Session (tracks local Claude Code / Codex CLI sessions), ANE Memory. Suspends automatically when fully occluded or the user is away.
- **Now Playing** (`LiveWallpaper/Monitor/NowPlaying/`, `LiveWallpaper/Monitor/Widgets/NowPlaying*`) — the current Spotify or Apple Music track, in Poster, Vinyl, or Aurora style, with cover-derived accent colors and five audio-reactive effects when Audio Response is on. It is its own overlay layer, switched on and positioned independently of the Monitor board (nine-point anchors or dragging it in the preview), and it disappears entirely while nothing is playing.
  - **How it reads the track:** the players' own `DistributedNotificationCenter` broadcasts. No polling, no helper process, no Media Remote private API.
  - **Transport controls** appear on hover and drive the player over Apple Events, which macOS gates behind an Automation prompt on first use; declining leaves the buttons inert and changes nothing else.
  - **Lyrics** (optional) come from the public LRCLIB service, matched on artist/title/album. Spotify reports a playback position, so its lyrics follow the song line by line; Apple Music broadcasts no position, so its lyrics stand still at the top.
  - **Network discipline:** cover art and lyrics are fetched from a fixed allow-list of hosts (`open.spotify.com`, `itunes.apple.com`, `lrclib.net`, and the Spotify/Apple cover CDNs) over HTTPS only, with streamed size caps, redirects off the list refused, and both a positive LRU cache and a TTL'd negative cache (`NowPlayingNetwork.swift`).

## 4) Performance model

`LiveWallpaper/Policies/WallpaperPolicyEngine.swift` separates **safety
suspends** (user absent, critical memory pressure, critical thermal state —
cannot be overridden) from **discretionary suspends** (full-screen, ≥85 % window
occlusion, battery, Low Power Mode, per-app rules). Moderate heat (`serious`)
**throttles** the frame rate of scene and web wallpapers instead of stopping
them, and a memory `warning` throttles scenes — a busy scene idles near those
levels in normal use. Video has no frame-rate knob to shed load with, so
moderate heat still suspends it.

- **App exceptions** (`Schema/ApplicationPerformanceRule.swift`) — three triggers per app: pause when frontmost, pause while running, or **never pause** (vetoes discretionary suspends only). This is also the way to handle games: full-screen detection catches most, and an explicit rule covers the rest.
- **No suspend ever changes your play intent** — intent lives in one per-screen
  state machine (`LiveWallpaperCore … WallpaperPlaybackStateMachine.swift`) that
  only the play/pause controls can write, so wallpapers always resume on their
  own once the condition clears, and the play button can never strand one.
- When a system rule is holding a wallpaper down, the menu bar and the screen's
  detail header say **which** rule (battery, full-screen, heat, …).
- A manual pause keeps the last frame on screen and releases the decoder and
  caches after 5 minutes — the same wall clock for video, web and scene
  wallpapers alike.
- Pro adds adaptive frame rate under occlusion and per-display render threads.

## 5) Multi-display

- Independent config per display (`LiveWallpaper/App/ScreenManager+Screens.swift`).
- Copy one display's setup to all; span one video across all displays.
- Sidebar display order persists (`LiveWallpaper/Models/SidebarDisplayOrder.swift`).

## 6) Workshop (Pro)

- **SteamConnector** (`SteamConnector/`) — XPC helper that runs SteamCMD serially, verifies its code signature and SHA-256, discovers cached Steam logins, and downloads Workshop items with your account.
- **Managed SteamCMD install** (`Workshop/SteamCMDManagedInstallCoordinator.swift`) — the app asks, the connector does the work: fetch Valve's package manifest, download each package, reject anything whose SHA-256 doesn't match the manifest, unpack into a staging directory, and keep the result only if the installed binary's code signature and team identifier are Valve's. A failure at any step rolls back to whatever was installed before. Additive — package-manager detection and manually chosen binaries are unchanged, and every run path applies the same trust gates.
- **Online browse** (`LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift`) — Steam Web API queries with paging, caching, rate limiting, creator resolution; maturity blur and content filters in settings.
- **Engine assets** (`LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift`) — one-time SteamCMD download of shared Wallpaper Engine assets, with build-ID update checks.
- **Doctor** (`LiveWallpaper/Infrastructure/Workshop/Doctor/`) — guided setup and diagnostics for the whole chain.

## 7) Updates (both editions)

`LiveWallpaper/Infrastructure/Services/SparkleUpdaterController.swift` — Sparkle
handles checking, downloading and installing. Updates are verified against an
ed25519 public key pinned in each edition's `Info.plist`, so an update that is
not signed by the release key is refused outright; the feed is HTTPS-only.

Scheduled checks are deliberately quiet. Sparkle would normally raise its alert
the moment it finds something, which over a full-screen wallpaper is an
interruption nobody asked for; the gentle-reminder delegate suppresses that and
lights up the menu bar **Update** button instead. Clicking it hands control to
Sparkle's own install UI. Automatic checking can be turned off in
**Settings → General**, and the **Settings → About** banner reports the same
state plus a manual check.

Because the app is sandboxed it cannot replace its own bundle: Sparkle brokers
the install through an XPC service that runs outside the sandbox, which is what
`SUEnableInstallerLauncherService` and the `-spks`/`-spki` mach-lookup
entitlements are for. Each edition has its own appcast (`appcast-pro.xml`,
`appcast-lite.xml`), regenerated at release time by
`scripts/generate-appcast.sh`, because the two ship as separate DMGs and an
enclosure can only point at one of them. Sparkle orders updates by
`CFBundleVersion`, which both plists set to `MARKETING_VERSION`. Packaging
re-signs Sparkle's nested installer helpers so they share the app's Team ID.

## 8) Security & privacy

- No telemetry, no accounts.
- Workshop API key is stored in Loomscreen's sandboxed Application Support
  directory with owner-only permissions. Loomscreen does not intentionally
  sync it; normal Mac backup and migration behavior remains a system policy.
- Web wallpapers render in sandboxed contexts; optional tracker blocking and CSP enforcement.
- File access uses security-scoped bookmarks; permission prompts are listed in [install.md](install.md#system-permission-prompts).

## 9) Code entry points

- Capability gating: `Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift`
- Screen orchestration: `LiveWallpaper/App/ScreenManager.swift` (+ extensions in `LiveWallpaper/App/`)
- Policies (pause/playlist/schedule): `LiveWallpaper/Policies/`
- Display detail UI: `LiveWallpaper/Views/ScreenDetail*`
- Menu bar: `LiveWallpaper/Views/MenuBarContent.swift`
- Settings: `LiveWallpaper/Views/Settings/`
- WPE runtime: `LiveWallpaper/Runtime/` (Metal renderer, scene runtime)
- Workshop stack: `LiveWallpaper/Infrastructure/Workshop/`, `SteamConnector/`
