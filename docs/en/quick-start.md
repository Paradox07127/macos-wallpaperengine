# Quick Start

**English** · [简体中文](../zh-Hans/quick-start.md)

From zero to your first wallpaper, then the features you'll actually use daily.
Install steps live in [install.md](install.md); the full feature ↔ code map in
[features.md](features.md).

## 1) First launch

After [installing](install.md), launch Loomscreen. A floating **Welcome Tour**
highlights the controls on the actual workspace. You can close it and start
using the app, reopen it from **Settings → About → Welcome Tour**, or use a
page's **Explain This Page** button for a shorter guide.

Start in **Overview**:

- Drag a video (`mp4`/`m4v`/`mov`/`avi`), web folder or, in Pro, a Wallpaper Engine project onto a display.
- Open a display to choose a file, enter a web source or choose from **Wallpaper Library**, including Apple Aerials already downloaded on your Mac.
- Apply to a named display, or use the apply-to-all action for the same wallpaper on every display.

[Workspace guide](workspace.md) explains the overview, shelf, library and display editor.

## 2) Know the two surfaces

- **Menu bar icon** — day-to-day control: add a wallpaper, global on/off, per-display play/pause and prev/next, volume, live CPU/GPU/RAM/thermal strip, reload, quit.
- **Management window** (menu bar → **Manage**) — the top navigation opens **Overview**, **Wallpaper Library**, **Schemes**, **System Wallpaper**, **Workshop** (Pro), and **Settings**. Overview shows your displays; click one to edit it. Settings has its own sidebar for General, Display Defaults, Performance, Integrations, Shortcuts, Backup and the other settings pages.

Closing the management window keeps Loomscreen and its wallpapers running. Use the menu bar icon → **Manage** to return. New installations also show the app in the Dock and Command-Tab by default; **Settings → General → Show in Dock** controls this. Existing saved preferences are preserved. Choose **Quit** in the menu bar to stop the app.

## 3) Configure one display end-to-end

1. Open **Overview** and click the display you want to change.
2. Use **Change Wallpaper**, or choose a wallpaper in **Wallpaper Library** and apply it to the named display. Scene wallpapers require Pro.
3. In **Wallpaper**, use the preview controls for fit, audio and frame rate; the inspector shows the selected type's additional options. Video adds speed and color effects; web adds JavaScript, tracking protection, CSS and refresh; scenes expose their author's custom properties and presets.
4. Frame-rate controls accept a custom integer up to that display's current refresh rate, plus **Max**. Presets include 15/24/30/45/60/120 where the display supports them. The selected value is a ceiling, not a measurement of achieved frames.
5. **Overlays** opens one canvas with a layer list, an object inspector and an add palette. Add widgets, a clock or music, then select and position them. The effect layer contains particles and weather response. Sample Data previews layout without claiming to show live measurements.

   With widget interaction enabled, only visible widget areas receive clicks; empty desktop areas stay click-through. Selecting and moving objects in the overlay editor remains interactive.

6. Ordinary property edits save as you interact. **Wallpaper Automation** is a separate draft editor with **Save** and **Cancel**.

## 4) Playlists and rotation

Open **Wallpaper Automation** from the display's top bar. Its modes are
**Playlist**, **Daily Schedule** and **Library Shuffle**. In **Playlist**:

- Add wallpapers from the library, including video, web and scene entries supported by your edition.
- Use each row's arrows to reorder, its play button to try it on this display, and its remove button to remove it from the queue.
- Select **Manual** or a rotation interval of 1, 5, 15, 30, 60 or 120 minutes, and optionally enable **Shuffle**.
- **Save** commits the draft. **Cancel** discards draft changes and restores the configuration from before trial playback.

Prev/next also appear in the menu bar for displays running a playlist.

**Library Shuffle** needs no list: it picks a random wallpaper from your whole
library at the interval you choose. **Next Random Wallpaper** skips ahead.

Picking a wallpaper yourself, applying a scheme or applying a Workshop item
(Pro) restarts the countdown. A wallpaper that fails to load twice moves to
**Skipped wallpapers** with its reason; **Enable Again** brings it back.

## 5) Time-of-day schedule

Switch the same editor to **Daily Schedule**. Slots sit on a **24-hour
schedule** dial. Select a slot to pick its wallpaper and hours; drag the ends of
its arc to change the hours; double-click an empty hour to add a slot.
Overlapping ranges show an error and prevent saving. A range can cross midnight.
**Save and Use Daily Schedule** switches the display to that mode. **Unscheduled
Hours** sets the wallpaper for hours no slot covers. Automation pauses while you're away
(lock or display sleep), then reconciles on wake rather than replaying missed slots.

## 6) Bookmarks and schemes

Mark wallpapers you use often with the yellow bookmark, from a wallpaper's menu
or its detail, then pick the **Bookmarks** filter in the **Wallpaper Library** to
list only those. Use the **Schemes** page for a full display setup, including
playback, overlays, playlist and schedule. Applying a scheme replaces that
display's setup after confirmation. Schemes reference local files; moving them
to another Mac may require selecting those files again.

## 7) Global shortcuts

**Settings → Shortcuts** — a master switch plus eight bindable actions:
play/pause all, next / previous wallpaper (display under cursor), toggle mute,
toggle mouse interaction, show/hide all wallpapers, reload all wallpapers,
open the settings window.

## 8) Workshop setup (Pro)

Start in **Workshop** to search, filter, sort and inspect public wallpapers; public browsing does not require SteamCMD, a sign-in or an API key. An installed item can be applied directly to a named display. When you need to download content, the app guides you through setup:

1. Open **Settings → Workshop**. A status bar across the top of the page shows where each of the three prerequisites stands, and the **Steam connection** section below lists them step by step and offers auto-configuration.
2. **SteamCMD** — downloads run through Valve's command-line tool using your own
   Steam account; accounts with a cached login are discovered and offered
   automatically. Until the tool is ready, the **SteamCMD** row offers
   **Set up SteamCMD**, **Locate automatically** and **Choose SteamCMD**; once
   it is ready, the row offers **Change**, **Locate automatically** and
   **Set up SteamCMD**:
   - **Set up SteamCMD** — opens a dialog with two choices.
     **Install with Loomscreen** shows the download size and where the copy will
     go, and **Download and install** installs a managed copy. It fetches Valve's
     package manifest, checks every download against the manifest's SHA-256,
     unpacks it, and keeps the result only if the binary's code signature and
     team identifier are Valve's. If any step fails it rolls back and leaves
     your previous setup alone. **Install with Homebrew** shows a Terminal
     command with a **Copy** button; run it, then use **Locate automatically**.
   - **Locate automatically** — finds an existing install (Homebrew,
     `/usr/local/bin`, and friends).
   - **Choose SteamCMD** (**Change** once the tool is ready) — point at a binary
     yourself. It goes through the same signature and checksum gates as
     everything else, on every run rather than only when you pick it.
   - The `⋯` menu beside the buttons appears only when there is something to
     undo: **Forget the SteamCMD I chose** goes back to automatic detection, and
     **Remove the copy Loomscreen installed** deletes the managed copy after you
     confirm.
3. **Steam Web API key** — enables API-backed browsing, creator metadata and preset lists; public browsing and download-by-link can be used without it. Get a key at [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey). New keys are stored in the login Keychain; older file-based keys migrate when Keychain access succeeds.
4. **Engine assets** — scenes reference shared Wallpaper Engine assets; Loomscreen downloads them once via SteamCMD and can check for updates on launch (**Settings → Workshop**).

Sign in with your Steam account through the guided flow; Steam Guard is supported.
Downloads use the authorized Steam library and subscription sync makes your
subscribed items available in the app. You can also link local project folders,
which are read in place. Browse filters apply within tag/creator views as well.

Open **Downloads** in the Workshop toolbar to see queued, active and finished
downloads. Failed items retain their reason and offer **Retry**; queued and active
items offer **Cancel**. Completed and cancelled items last for the current app
session; failed items survive restarts until dismissed or retried. Progress shows
a percentage when Steam reports one or downloaded bytes and a total are known;
otherwise it shows an activity indicator. Waiting and SteamCMD restarts have their
own status. A failed thumbnail offers **Retry thumbnail** without downloading the
wallpaper again.

## 9) Scene presets (Pro)

A wallpaper's page in the Workshop also lists the **presets** its community has
published — a preset is a saved set of that wallpaper's own settings, plus the
colour correction and volume its author chose. Download one and it appears in
the **Preset** row of the scene settings card.

**Settings → Workshop → Show presets as wallpapers** is off by default; turn it
on to include presets in the general browse grid. The base wallpaper's detail
page still provides its preset list.

The row separates *Saved by you* from *From the Workshop*, and its menu offers
**Save as New Preset**, **Rename**, and **Delete preset**. When the applied
preset is one you saved and you have changed values since, the menu also offers
**Update “*name*”** to save those changes into it. A
preset is a layer over the scene's defaults, and your own tweaks are a layer on
top of that — so anything you change afterwards stays yours, and deleting the
preset keeps your changes.

## 10) Music, weather and system playback

- **Overlays**: select Music in the add palette or layer list, enable the layer, pick Poster/Vinyl/Aurora, drag it in
  the preview and choose whether to show controls and lyrics. Lyrics are off
  by default. Spotify/Music Automation permission enables controls and missing
  playhead reads; Pro Audio Response enables reactive visuals.
- **Overlays**: add a Weather tile from the palette alongside CPU, Memory or other
  widgets. Choose system/manual location under **Settings → Integrations → Weather**.
- **System Wallpaper** (macOS 26+): add a supported video and open macOS
  Wallpaper settings to select it. The system provider can continue playing
  with Loomscreen closed. This path does not include scenes, web or overlays,
  and availability depends on the provider's compatibility check.

## 11) After the first day

- Revisit **Settings → Performance**: pause rules (full-screen, battery, Low Power Mode, occlusion), per-app exceptions — including **never pause** for apps that should always keep the wallpaper alive — and the video RAM preload budget.
- Choose a **Wallpaper transition** and an **Opening animation** in **Settings → General → Wallpaper**.
- Export a `.lwconfig` backup from **Settings → Backup & Restore**. It saves settings and references, not the media files or secrets. Lite cannot run scene entries from a Pro backup.
- Hit an edge case? **Settings → About → Report a Bug** pre-fills diagnostics.

The Workshop browser retains its query, filters, page, and selected item when switching between pages in the management window, including Settings and the wallpaper library. This browsing session ends when the management window is destroyed; it is not persisted across app restarts.

## Like Workshop wallpapers for later

Use the pink heart on a Workshop catalog card, its context menu, or the detail view to like a wallpaper before downloading it. Turn on **Liked** in the Workshop filter bar to see what you liked, open details, and download later. Liking is local and does not download, subscribe to, or apply the item. Pro `.lwconfig` exports include your likes. They do not include the downloaded wallpaper media.
