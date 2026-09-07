# Quick Start

**English** · [简体中文](../zh-Hans/quick-start.md)

From zero to your first wallpaper, then the features you'll actually use daily.
Install steps live in [install.md](install.md); the full feature ↔ code map in
[features.md](features.md).

## 1) First launch

After [installing](install.md), launch Loomscreen. Onboarding opens:

- **Import a File** → video (`mp4`/`m4v`/`mov`/`avi`), web page (`.html` or a folder), or — on Pro — a Wallpaper Engine scene folder.
- **Apple Aerials** → pick from the aerial videos already downloaded on your Mac.
- With multiple displays, apply to one display or choose **All Displays**.

Skipping onboarding is fine — everything below works from the Settings window.

## 2) Know the two surfaces

- **Menu bar icon** — day-to-day control: add a wallpaper, global on/off, per-display play/pause and prev/next, volume, live CPU/GPU/RAM/thermal strip, reload, quit.
- **Settings window** (menu bar → **Manage**) — sidebar lists your **Displays**, plus **Saved** (wallpapers and schemes), **Apple Aerials**, (Pro) **Steam Workshop**, and **System Wallpaper** on macOS 26+; the settings tabs (General, Display Defaults, Performance, Weather, Shortcuts, Backup…) live in the same window.

## 3) Configure one display end-to-end

1. **Settings → Displays** → pick a display.
2. Choose the wallpaper type: **Video / Web / Scene** (Scene is Pro-only; Lite shows only what it can render).
3. Pick the source in the preview area — file picker or drag & drop onto the display row.
4. Tune in the inspector:
   - **Wallpaper** tab — volume/mute, frame-rate target (15/30/60/match display; labels show the effective rate), fit mode, video color space (including HDR), playback speed; web pages add JavaScript, tracker blocking, custom CSS, and auto-refresh; scenes add cursor parallax, click interaction, and a **Preset** row.
   - **Overlays** tab — choose **Weather**, **Widgets** or **Music**. Configure 12 particle effects and weather response, arrange ten widget types including Weather, or enable a separate Now Playing layer. Each category has its own preview; drag to place widgets or the music layer.
5. State persists as you interact — there is no separate save step.

## 4) Playlists and rotation

In the display's **Playlist** section:

- Add videos, reorder by drag, remove entries.
- Set the rotation interval (1–1440 minutes) and toggle **Shuffle**.
- Apply to the current display or all displays.

Prev/next also appear in the menu bar for displays running a playlist.

## 5) Time-of-day schedule

In the **Schedule** section, add slots from presets (Morning, Midday, Afternoon,
Evening, Night) or a custom range, then attach a bookmark to each. Overlapping
slots are flagged. When no slot matches, the display returns to its primary
wallpaper. Automation sleeps whenever you're away (lock, display sleep) and
reconciles once on wake — missed slots don't fire retroactively.

## 6) Saved wallpapers and schemes

Save a wallpaper from the display header, then find it under **Saved → Bookmarks**.
A bookmark changes the content while preserving the target display's settings.
Use **Saved → Schemes** for a full display setup, including playback, overlays,
playlist and schedule. Applying a scheme replaces that display's setup after
confirmation. Schemes reference local files; moving them to another Mac may
require selecting those files again.

## 7) Global shortcuts

**Settings → Shortcuts** — a master switch plus eight bindable actions:
play/pause all, next / previous wallpaper (display under cursor), toggle mute,
toggle mouse interaction, show/hide all wallpapers, reload all wallpapers,
open the settings window.

## 8) Workshop setup (Pro)

The Steam Workshop page needs one-time setup, guided in-app:

1. Open **Settings → Workshop**. A status bar across the top of the page shows where each of the three prerequisites stands, and the **Steam connection** section below lists them step by step and offers auto-configuration.
2. **SteamCMD** — downloads run through Valve's command-line tool using your own
   Steam account; accounts with a cached login are discovered and offered
   automatically. Three ways to get the tool, all on the **SteamCMD** row —
   the button is the common one for your current state, the `⋯` menu beside it
   holds the rest:
   - **Install SteamCMD…** — Loomscreen installs a managed copy. It fetches
     Valve's package manifest, checks every download against the manifest's
     SHA-256, unpacks it, and keeps the result only if the binary's code
     signature and team identifier are Valve's. If any step fails it rolls back
     and leaves your previous setup alone.
   - **Locate automatically** — finds an existing install (Homebrew,
     `/usr/local/bin`, and friends).
   - **Choose SteamCMD…** — point at a binary yourself. It goes through the same
     signature and checksum gates as everything else, on every run rather than
     only when you pick it.
3. **Steam Web API key** — enables API-backed browsing, creator metadata and preset lists; public browsing and download-by-link can be used without it. Get a key at [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey). New keys are stored in the login Keychain; older file-based keys migrate when Keychain access succeeds.
4. **Engine assets** — scenes reference shared Wallpaper Engine assets; Loomscreen downloads them once via SteamCMD and can check for updates on launch (**Settings → Workshop**).

Sign in with your Steam account through the guided flow; Steam Guard is supported.
Downloads use the authorized Steam library and subscription sync makes your
subscribed items available in the app. You can also link local project folders,
which are read in place. Browse filters apply within tag/creator views as well.

## 9) Scene presets (Pro)

A wallpaper's page in the Workshop also lists the **presets** its community has
published — a preset is a saved set of that wallpaper's own settings, plus the
colour correction and volume its author chose. Download one and it appears in
the **Preset** row of the scene settings card.

**Settings → Workshop → Show presets as wallpapers** is off by default; turn it
on to include presets in the general browse grid. The base wallpaper's detail
page still provides its preset list.

The row separates *Saved by you* from *From the Workshop*, and its menu offers
**Save current values as a preset…**, **Rename…**, and **Delete preset**. A
preset is a layer over the scene's defaults, and your own tweaks are a layer on
top of that — so anything you change afterwards stays yours, and deleting the
preset keeps your changes.

## 10) Music, weather and system playback

- **Overlays → Music**: enable the layer, pick Poster/Vinyl/Aurora, drag it in
  the preview and choose whether to show controls and lyrics. Lyrics are off
  by default. Spotify/Music Automation permission enables controls and missing
  playhead reads; Pro Audio Response enables reactive visuals.
- **Overlays → Widgets**: add a Weather tile alongside CPU, Memory or other
  widgets. Choose system/manual location under **Settings → Weather**.
- **System Wallpaper** (macOS 26+): add a supported video and open macOS
  Wallpaper settings to select it. The system provider can continue playing
  with Loomscreen closed. This path does not include scenes, web or overlays,
  and availability depends on the provider's compatibility check.

## 11) After the first day

- Revisit **Settings → Performance**: pause rules (full-screen, battery, Low Power Mode, occlusion), per-app exceptions — including **never pause** for apps that should always keep the wallpaper alive — and the video RAM preload budget.
- Export a `.lwconfig` backup from **Settings → Backup & Restore**. It saves settings and references, not the media files or secrets. Lite cannot run scene entries from a Pro backup.
- Hit an edge case? **Settings → About → Report a Bug…** pre-fills diagnostics.
