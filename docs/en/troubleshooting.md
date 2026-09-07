# Troubleshooting

**English** · [简体中文](../zh-Hans/troubleshooting.md)

## Install & launch

| Problem | Check | Fix |
|---|---|---|
| "Loomscreen.app is damaged / can’t be opened" | Gatekeeper may block the non-notarized build; this message alone does not establish the cause | Verify the DMG checksum, then follow the matching Lite/Pro command in [Install](install.md); if it persists, collect the launch error |
| Menu bar icon missing | Is the app running (Activity Monitor)? Crowded menu bar? | Relaunch from `/Applications`; check login-item restrictions |
| App won't launch at all | macOS 14.6+? Pro additionally needs Apple Silicon | Lite ships an untested Intel slice; Pro is Apple Silicon only |

## Rendering

| Problem | Check | Fix |
|---|---|---|
| Nothing renders / black wallpaper | Is a source assigned in **Settings → Displays**? Is the global toggle on? | Assign a source; toggle the menu bar master switch off/on |
| Wallpaper keeps pausing | Pause rules: full-screen, ≥85 % occlusion, battery, Low Power Mode, app exceptions | The menu bar and the screen's detail header name the rule that is holding it. For discretionary rules, adjust **Settings → Performance** or add a **never pause** exception; safety suspends cannot be overridden |
| Second display stays blank | Does the source's file permission cover that display's config? | Re-open the display's detail panel and re-assign the source explicitly |
| Large video stutters | Source resolution/codec, overlays and resource pressure | Try a lower-resolution source, adjust the frame-rate target and disable overlays to isolate; changing preload trades RAM for disk/decoder work |
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
| Scene import fails immediately (Pro) | A project needs `project.json`; a library contains project subfolders | Choose the project or supported library folder; inspect the reported failure. Windows executable wallpapers are unsupported |

## Workshop (Pro)

| Problem | Check | Fix |
|---|---|---|
| Downloads fail | SteamCMD state, Steam login | Open **Settings → Workshop** — the **Steam connection** section diagnoses the Steam library, SteamCMD, and your account, and can auto-configure. Expand **Diagnostics** in that section for the individual probes |
| **Install SteamCMD…** fails | The failure message identifies manifest, download, checksum or signature validation | Retry; a mismatch can be an incomplete download or trust failure, not proof of a specific cause. Do not bypass verification; use a verified existing install if needed |
| A SteamCMD you picked stops working | It's re-verified on **every** run, not only when you chose it — an upgrade that changed its signature will be rejected | Re-pick it with **Choose SteamCMD…**, or switch to a managed install |
| Browse shows nothing | Filters, connectivity, and API-key status for API-only features | Clear restrictive filters and retry. Public browsing can work without a key; creator/preset/API queries may require one. Presets are hidden from general browse by default |
| Preset list on a wallpaper is empty | Presets need a Steam Web API key to list, and SteamCMD to download | Add the key first; "No presets have been published for this wallpaper" means exactly that |

## Overlays, backup and updates

| Problem | Check / next step |
|---|---|
| Apple Music progress or controls are unavailable | Allow Loomscreen to automate Music in macOS Privacy & Security → Automation. A track without a usable playhead cannot provide timed progress |
| Lyrics are missing or static | Enable lyrics, check connectivity and track matching; not every track has timed LRCLIB lyrics |
| Weather widget has no current conditions | Select a system/manual location and check Weather settings and network access |
| Imported backup contains a scene but Lite shows no wallpaper | Lite preserves configuration data but cannot run Pro scenes. Select a supported video/web source or open the setup in Pro |
| System Wallpaper is unavailable | It requires macOS 26+ and a compatible provider. Use the app's normal video path if its status says the provider is paused; adding a video still requires selection in macOS Wallpaper settings |
| Update banner remains after dismissing an update | The retained Sparkle session can keep the badge visible; use the update dialog for its actions. This is not a second download |
| Update download/verification fails | Retry on a working connection; do not bypass signature verification. A matching manual DMG and checksum are available from Releases |

## Still stuck?

1. Toggle the relevant pause rules in **Settings → Performance** and retest.
2. Export your config (**Settings → Backup & Restore**) before experimenting.
3. **Settings → About → Report a Bug…** pre-fills diagnostics and recent log
   lines — attach reproduction steps and file an
   [issue](https://github.com/Paradox07127/macos-wallpaperengine/issues).
