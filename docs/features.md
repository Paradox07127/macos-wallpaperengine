# Feature Guide

The authoritative map from user-facing features to their implementation. For a
task-oriented walkthrough, use [quick-start.md](quick-start.md) instead.

Authoritative capability gate: [`ProductCapabilities.swift`](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## 0) App surfaces

- **Menu bar** (`LiveWallpaper/Views/MenuBarContent.swift`)
  - Quick-add wallpaper, global on/off toggle.
  - Per-display rows: status, play/pause, prev/next (playlist mode), volume.
  - Live usage strip (CPU / GPU / RAM / thermal pressure).
  - Manage, General Settings, reload-all, quit.
- **Settings window** (`LiveWallpaper/Views/ContentView.swift`, `LiveWallpaper/Views/Settings/SettingsNavigation.swift`)
  - Sidebar: per-display pages, Bookmarks, Apple Aerials, Steam Workshop (Pro).
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
| About | both | Version, links, Welcome Tour; **Lite adds** the update banner |

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

## 2) Playback & automation

- **Playlists** (`LiveWallpaper/Views/PlaylistSection.swift`, `LiveWallpaper/Policies/PlaylistPolicy.swift`) — drag-reorder, shuffle, 1–1440 min rotation, apply to one or all displays.
- **Schedule** (`LiveWallpaper/Views/ScheduleSection/`, `LiveWallpaper/Policies/SchedulePolicy.swift`) — time slots with presets, conflict detection, fallback to the primary wallpaper.
- **Coordinator** (`LiveWallpaper/Policies/WallpaperAutomationCoordinator.swift`) — one 60-second tick, running only while some display actually has automation; stops entirely during lock/sleep and reconciles once on wake.
- **Bookmarks** (`Schema/WallpaperBookmark.swift`, `LiveWallpaper/App/ScreenManager+Bookmarks.swift`) — snapshot content plus playback/overlay state. The Monitor board layout deliberately stays per-display and is not part of a bookmark.
- **Import routing** (`LiveWallpaper/Infrastructure/Assets/WallpaperImportRouter.swift`) — one classifier behind the toolbar picker, drag & drop, and onboarding: video / scene project / scene library / html / unsupported.

## 3) Overlays

All overlays are renderer-independent — they stack on video, web, and scene
wallpapers alike.

- **Particles** (`Schema/ParticleEffect.swift`) — Snow, Rain, Bokeh, Fireflies, Dust, Stars, Leaves, Sakura.
- **Weather-reactive** (`LiveWallpaper/Runtime/WeatherReactiveService.swift`) — hourly Open-Meteo conditions map to particle effects and video adjustments (saturation, brightness, temperature…). Location: off / system / manual.
- **Monitor board** (`LiveWallpaper/Monitor/`) — per-display, desktop layer (click-through) or always-on-top. Widgets: CPU, Memory, GPU, Network, Disk, Power, Processes, Agent Session (tracks local Claude Code / Codex CLI sessions), ANE Memory. Suspends automatically when fully occluded or the user is away.

## 4) Performance model

`LiveWallpaper/Policies/WallpaperPolicyEngine.swift` separates **safety
suspends** (user absent, memory pressure, thermal protection — cannot be
overridden) from **discretionary suspends** (full-screen, ≥85 % window
occlusion, battery, Low Power Mode, per-app rules).

- **App exceptions** (`Schema/ApplicationPerformanceRule.swift`) — three triggers per app: pause when frontmost, pause while running, or **never pause** (vetoes discretionary suspends only). This is also the way to handle games: full-screen detection catches most, and an explicit rule covers the rest.
- Memory-pressure suspends never change your play intent — wallpapers resume when pressure clears (`LiveWallpaper/App/ScreenManager+MemoryPressure.swift`).
- Pro adds adaptive frame rate under occlusion and per-display render threads.

## 5) Multi-display

- Independent config per display (`LiveWallpaper/App/ScreenManager+Screens.swift`).
- Copy one display's setup to all; span one video across all displays.
- Sidebar display order persists (`LiveWallpaper/Models/SidebarDisplayOrder.swift`).

## 6) Workshop (Pro)

- **SteamConnector** (`SteamConnector/`) — XPC helper that runs SteamCMD serially, verifies its code signature and SHA-256, discovers cached Steam logins, and downloads Workshop items with your account.
- **Online browse** (`LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift`) — Steam Web API queries with paging, caching, rate limiting, creator resolution; maturity blur and content filters in settings.
- **Engine assets** (`LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift`) — one-time SteamCMD download of shared Wallpaper Engine assets, with build-ID update checks.
- **Doctor** (`LiveWallpaper/Infrastructure/Workshop/Doctor/`) — guided setup and diagnostics for the whole chain.

## 7) Updates (Lite)

`LiveWallpaper/Infrastructure/Services/UpdateChecker.swift` — GitHub Releases
check at launch, 12-hour throttle, 1-hour failure backoff, skip-a-version
support. Hardened: trusted host only, 512 KB response cap, release-notes
truncation, URL allowlisting. It only opens the Releases page — nothing
auto-installs. Pro has no in-app updater.

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
