# Feature Guide

**English** · [简体中文](../zh-Hans/features.md)

For setup steps, see [Quick Start](quick-start.md). For module ownership and
rendering data flow, see [Architecture](architecture.md). Edition availability
is defined by [ProductCapabilities.swift](../../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift)
and the app target's build gates.

## App surfaces

- **Menu bar**: add a wallpaper, global on/off, per-display playback and volume,
  playlist navigation, CPU/GPU/RAM/thermal status, updates, settings and quit.
- **Settings window**: Displays, **Saved** (wallpapers and display schemes),
  Apple Aerials, Steam Workshop (Pro), and System Wallpaper (macOS 26+).
- **Display inspector**: Wallpaper and Overlays tabs. Overlays has separate
  Weather, Widgets and Music pages, each with its own controls and preview.
- **Languages**: English, Simplified Chinese, Traditional Chinese, Japanese and Spanish.

| Settings page | Edition | Contents |
|---|---|---|
| General | both | Language, login behavior, Dock visibility, lock-screen frame capture, automatic update checks |
| Display Defaults | both | Playback, frame rate, fit, color and interaction defaults |
| Performance | both | Pause rules, app exceptions, video preload; Pro adds adaptive scene frame rate and render threads |
| Audio Response | Pro | System audio capture for scene and music visual effects |
| Weather | both | Off, system location or manual location |
| Shortcuts | both | Master switch and eight bindable actions |
| Storage | Pro | Downloaded projects, engine assets and caches |
| Backup & Restore | both | Configuration export/import |
| Workshop | Pro | Steam setup, API key, engine assets and browse preferences |
| Advanced / About | both | Diagnostics, maintenance, version, links and updates |

## Wallpaper types

### Video — both editions

- `mp4`, `m4v`, `mov` and `avi`, subject to the codecs available to AVFoundation.
- Fill, Fit and Stretch; playback speed, mute/volume and video effects.
- Auto, sRGB, Display P3, Rec. 2020 HDR and force-SDR color modes.
- Independent display playback or a video spanned across displays.
- Configurable per-display RAM preload budget.
- Frame-rate targets of 15, 30, 60 or **match display**. Controls show the
  effective rate available on that display; video is also bounded by its source
  rate. Saved settings from earlier frame-rate formats migrate on load.

### Web — both editions

URLs, HTML files, local folders and inline HTML run in WKWebView. Settings
include JavaScript and mouse interaction, tracker blocking, custom CSS,
mute/volume, refresh interval, scale/pan/rotation and physical-pixel layout.
Workshop web imports use ephemeral storage and network isolation. User-created
web sources can use the network according to their settings.

### Apple Aerials — both editions

Browse, search and apply aerial videos macOS has already downloaded. Aerials
use the video playback path; Loomscreen does not download the Apple catalog.

### Wallpaper Engine scenes — Pro

Local project folders and downloaded Workshop content are read in place.
The native Metal renderer supports layered scenes, particles, puppet-warp
animation, text, SceneScript, audio response and cursor effects. Scene GLSL
is translated to Metal; it is not a separate wallpaper type.

Compatibility varies by project and feature. Import/preflight and runtime
errors describe unsupported content or missing assets; this is an independent
implementation, not a guarantee that every Windows project renders identically.
Windows executable wallpapers are not supported.

**Scene presets** store named values for a base wallpaper. Scene defaults,
a preset and per-display edits are separate layers. The Preset row offers
selection, save, rename and delete; Workshop detail pages list community
presets for the base wallpaper with a Steam Web API key, and link to them on
Steam without one.

Presets can also carry Wallpaper Engine color correction and volume. Color
correction runs as a full-frame pass when enabled and non-neutral; its curves
follow Loomscreen's video controls rather than claiming exact WPE parity.
Preset volume multiplies the display's volume. These engine settings are kept
separate from identically named project properties.

## Saved content and automation

- **Saved → Bookmarks**: bookmarks keep the wallpaper content. Applying one
  leaves the target display's playback and overlay settings in place.
- **Saved → Schemes**: a full display setup, including wallpaper, overlays,
  playback, effects, playlist and schedule. Applying a scheme replaces that
  display's setup after confirmation. Positions adapt to the target display.
- **Playlists**: videos, drag-reordering, shuffle and 1–1440 minute rotation.
- **Schedules**: time slots, conflict checks and fallback to the primary
  wallpaper. Automation pauses during lock/sleep and reconciles once on wake.
- **Shortcuts**: play/pause, next, previous, mute, mouse interaction, global
  wallpaper visibility, reload and settings — eight configurable actions.
- **Backup**: `.lwconfig` carries configurations, global settings, bookmarks
  and schemes. It does not package media files, Steam credentials or API keys.
  File grants are machine-specific; files may need to be selected again after
  moving a backup. Lite cannot play Pro-only scene configurations in a backup.

## Overlays

Overlays have per-display configuration and can accompany video, web or scenes.
Particles and the monitor/music layers can also run over the macOS desktop
without an active Loomscreen wallpaper session. Preview pages show one overlay
category at a time.

- **12 particle effects**: Snow, Rain, Bokeh, Fireflies, Dust, Stars, Leaves,
  Sakura, Mist, Embers, Bubbles and Meteors. Includes wind-aware effects,
  Reduce Motion handling and screen-capture visibility control.
- **Weather response**: Open-Meteo conditions drive particle selection and
  video adjustments, using system or manual location.
- **Monitor board**: ten widget types — CPU, Memory, GPU, Network, Disk, Power,
  Processes, Agent Session, ANE Memory and Weather. Widgets have supported
  small/medium/large sizes, drag arrangement, display scaling, options and
  layout import/export. The board can sit at the desktop or above windows.
  Unavailable readings are distinguished from zero; histories retain sampling
  gaps. Network/disk totals are monitoring-session estimates.
- **Weather widget**: a sky scene with condition/place caption, day/night
  appearance, clouds, precipitation and wind. It is separate from the
  display-wide weather-response controls.
- **Agent Session**: reads local Claude Code and Codex session records for
  status. ANE Memory reports memory, not neural-engine utilization.
- **Music / Now Playing**: independent Poster, Vinyl and Aurora layouts,
  cover-derived accents, drag placement and optional lyrics. Pro adds system
  audio-driven visual effects, including Wave, when Audio Response is enabled.

Track changes come from Spotify/Apple Music notifications, with a startup
state read when needed. Apple Music's missing playhead is queried through
Apple Events while the source is active, so progress and synchronized lyrics
can follow it when Automation permission is granted. Playback buttons and
seeking use the same permission boundary. Without a usable playhead or timed
lyrics, the display falls back rather than inventing timing.

Cover art and optional LRCLIB lyrics use HTTPS host allowlists, response-size
limits and caches. Lyrics are off by default. Preview artwork uses cached
content; it does not independently fetch a second copy.

## Performance and display lifecycle

The playback state machine keeps user play/pause intent separate from system
policy. Lock/sleep, critical memory pressure and critical thermal state are
safety suspends. Full-screen, window occlusion, battery, Low Power Mode and
per-app rules are configurable policies; **never pause** app rules only veto
the discretionary policies. Menu-bar and display status explain pause reasons.

Moderate thermal pressure reduces scene/web frame rates and can suspend video.
A manual pause retains a still frame and enters deeper resource hibernation
after the dwell period. Pro adds adaptive scene frame rates and per-display
render actors. Display configuration and sidebar ordering persist.

## Workshop — Pro

- Browse with paging, cache, maturity/type/resolution/genre/Miscellaneous
  filters and translated tags. Maturity starts at Everyone, matching what the
  signed-out Workshop page shows; the Questionable and Mature chips turn those
  ratings back on. Sort names, time windows and the search-field
  menu (Title & Description / Title Only / Description Only) use Steam's own
  wording; the default sort is Most Popular over one week and can be changed
  in Workshop settings.
- Public browsing works without a key and reads the page's own result data,
  so keyless cards carry author names and page counts. A stored key that Steam
  rejects switches browsing to the public path with a dismissible notice.
- Creator names load after initial results, and existing cards remain visible
  while filters refresh. Genre choices match any selected genre; Miscellaneous
  choices must all be present; tag/creator scopes retain the other filters.
- Detail pages show posted/updated dates, rating and comment counts, required
  items, grouped tags and links to the item's change notes, comments and
  collections on Steam.
- **Show presets as wallpapers** is off by default. Presets remain available
  through their base wallpaper's detail page.
- Steam setup supports managed SteamCMD installation, automatic detection and
  manual selection. The XPC connector verifies the tool and runs SteamCMD.
- In-app sign-in supports Steam Guard and cached accounts. Sessions are kept
  per account; downloads go to the authorized Steam library. Subscription sync
  makes subscribed items available in the app.
- Downloads are revalidated inside the authorized library before import;
  app-managed deletion and download mutations share repository coordination.
- Shared Wallpaper Engine assets can be linked or installed, with update checks.

## System Wallpaper — both editions, macOS 26+

The **System Wallpaper** library copies supported video files into the
provider's library. Choose them through macOS Wallpaper settings; the provider
can keep playing when Loomscreen is closed. This is a video-only system path,
separate from Loomscreen's scenes, web pages and overlay windows. The page
reports provider compatibility and can pause publishing on an unsupported
macOS build. See [Architecture](architecture.md#system-wallpaper-provider).

## Updates and privacy

Both editions use Sparkle with separate HTTPS appcasts and signed update
payloads. Scheduled checks can show Sparkle's update dialog; the menu-bar
Update button and About page also expose the update flow. Sparkle handles
download and installation, including relaunch. Automatic checking is controlled
in General settings. This is not a GitHub-API notification-only checker.

No Loomscreen account or usage telemetry is required. Optional online features
contact Steam, weather, artwork/lyrics or update services; remote web wallpapers
can contact their own sites. New Steam API keys are saved in the login Keychain;
legacy owner-only files are migrated after a verified Keychain write and can
remain when migration is refused. See [Security](../SECURITY.md) and
[permissions](install.md#system-permission-prompts).
