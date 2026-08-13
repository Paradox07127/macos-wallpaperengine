# Quick Start

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
- **Settings window** (menu bar → **Manage**) — sidebar lists your **Displays**, plus **Bookmarks**, **Apple Aerials**, and (Pro) **Steam Workshop** libraries; the settings tabs (General, Display Defaults, Performance, Weather, Shortcuts, Backup…) live in the same window.

## 3) Configure one display end-to-end

1. **Settings → Displays** → pick a display.
2. Choose the wallpaper type: **Video / Web / Scene** (Scene is Pro-only; Lite shows only what it can render).
3. Pick the source in the preview area — file picker or drag & drop onto the display row.
4. Tune in the inspector:
   - **Wallpaper** tab — volume/mute, frame-rate cap (15/24/30/60/off), fit mode, video color space (including HDR), playback speed; web pages add JavaScript, tracker blocking, custom CSS, and auto-refresh; scenes add cursor parallax and click interaction.
   - **Overlays** tab — particle effects (snow, rain, sakura, fireflies…), weather-reactive mode, and the Monitor board. Overlays stack on top of any wallpaper type.
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

## 6) Bookmarks

Bookmark any configured wallpaper from the display header. A bookmark snapshots
the content *and* its playback/overlay settings, so applying one restores the
whole look — from the Bookmarks library or straight from the menu bar.

## 7) Global shortcuts

**Settings → Shortcuts** — a master switch plus seven bindable actions:
play/pause all, next / previous wallpaper (display under cursor), toggle mute,
toggle mouse interaction, show/hide all wallpapers, reload all wallpapers.

## 8) Workshop setup (Pro)

The Steam Workshop page needs one-time setup, guided in-app:

1. Open **Steam Workshop** in the sidebar — the **Steam connection** page lists each prerequisite and offers auto-configuration.
2. **SteamCMD** — Loomscreen detects (or helps install) Valve's command-line tool and verifies its signature. Downloads run through it with your own Steam account; discovered accounts with cached logins are offered automatically.
3. **Steam Web API key** — needed only for *browsing* the Workshop in-app. Get one free at [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey); Loomscreen stores it in its sandboxed Application Support directory with owner-only permissions and does not intentionally sync it.
4. **Engine assets** — scenes reference shared Wallpaper Engine assets; Loomscreen downloads them once via SteamCMD and can check for updates on launch (**Settings → Workshop**).

Then browse, filter, and download scenes directly, or link a local scene folder
from disk — assets are read in place, not copied.

## 9) After the first day

- Revisit **Settings → Performance**: pause rules (full-screen, battery, Low Power Mode, occlusion), per-app exceptions — including **never pause** for apps that should always keep the wallpaper alive — and the video RAM preload budget.
- Export a `.lwconfig` backup from **Settings → Backup & Restore**.
- Hit an edge case? **Settings → About → Report a Bug…** pre-fills diagnostics.
