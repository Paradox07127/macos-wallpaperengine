# Troubleshooting

**English** · [简体中文](../zh-Hans/troubleshooting.md)

## Install & launch

| Problem | Check | Fix |
|---|---|---|
| "Loomscreen.app is damaged / can't be opened" | Gatekeeper quarantine flag on the ad-hoc-signed build — not actual damage | Run once: `xattr -dr com.apple.quarantine /Applications/Loomscreen.app`, then reopen |
| Menu bar icon missing | Is the app running (Activity Monitor)? Crowded menu bar? | Relaunch from `/Applications`; check login-item restrictions |
| App won't launch at all | macOS 14.6+ on Apple Silicon? | Intel Macs and older macOS are not supported |

## Rendering

| Problem | Check | Fix |
|---|---|---|
| Nothing renders / black wallpaper | Is a source assigned in **Settings → Displays**? Is the global toggle on? | Assign a source; toggle the menu bar master switch off/on |
| Wallpaper keeps pausing | Pause rules: full-screen, ≥85 % occlusion, battery, Low Power Mode, app exceptions | Intended behavior — relax rules in **Settings → Performance**, or add a **never pause** app exception |
| Second display stays blank | Does the source's file permission cover that display's config? | Re-open the display's detail panel and re-assign the source explicitly |
| Large video stutters | 4K+ source, high frame cap, active overlays? | Lower the frame cap and RAM preload budget; disable particle/weather overlays to isolate |
| Desktop clicks feel blocked (scenes) | Scene **click interaction** captures mouse clicks | Disable click interaction for that display and reload |

## Playlists & schedule

| Problem | Check | Fix |
|---|---|---|
| Schedule doesn't switch | Overlapping slots? Bookmark still valid? App paused at that time? | Fix highlighted conflicts; re-save the slot; note that automation sleeps while the screen is locked or asleep and reconciles **once** on wake — missed slots don't fire retroactively |
| Playlist interval ignored | At least two valid entries? Playlist mode on? | Reset the interval and re-save; after sleep/unlock the countdown restarts rather than resuming |

## Import

| Problem | Check | Fix |
|---|---|---|
| Web folder won't load | Can an index file be inferred from the folder? | Point at the `.html` file directly |
| Scene import fails immediately (Pro) | Does the folder contain a `project.json`? | Import the project folder itself, not a parent; projects requiring Windows executables are skipped by design |

## Workshop (Pro)

| Problem | Check | Fix |
|---|---|---|
| Downloads fail | SteamCMD state, Steam login | Open the **Steam connection** page in the Workshop sidebar — it diagnoses SteamCMD, accounts, and engine assets, and can auto-configure |
| **Install SteamCMD…** fails | The failure message names the step: manifest fetch, download, checksum, or signature | A rejected checksum or signature means the download wasn't Valve's — retry rather than working around it. Your previous setup is rolled back, not left broken. If it keeps failing, install SteamCMD yourself and use **Locate automatically** |
| A SteamCMD you picked stops working | It's re-verified on **every** run, not only when you chose it — an upgrade that changed its signature will be rejected | Re-pick it with **Choose SteamCMD…**, or switch to a managed install |
| Browse shows nothing | Steam Web API key set? | Add one in **Settings → Workshop** (free at steamcommunity.com/dev/apikey) |
| Preset list on a wallpaper is empty | Presets need a Steam Web API key to list, and SteamCMD to download | Add the key first; "No presets have been published for this wallpaper" means exactly that |

## Still stuck?

1. Toggle the relevant pause rules in **Settings → Performance** and retest.
2. Export your config (**Settings → Backup & Restore**) before experimenting.
3. **Settings → About → Report a Bug…** pre-fills diagnostics and recent log
   lines — attach reproduction steps and file an
   [issue](https://github.com/Paradox07127/macos-wallpaperengine/issues).
