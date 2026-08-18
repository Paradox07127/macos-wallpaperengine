# Install & update

**English** · [简体中文](../zh-Hans/install.md)

## Install (DMG)

1. Download the latest `Loomscreen-x.y.z.dmg` from
   [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest).
2. Open the DMG and drag **Loomscreen.app** into `/Applications`.
3. Clear the Gatekeeper quarantine **once** in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch Loomscreen — its icon appears in the menu bar.

### Why the `xattr` step?

Loomscreen has no paid Apple Developer ID yet, so the build is **ad-hoc signed**.
macOS Gatekeeper quarantines ad-hoc-signed apps and reports them as "damaged";
the one-time `xattr -dr com.apple.quarantine` clears that flag. After it, the app
launches like any other. (The DMG's `READ ME — first launch.txt` repeats this.)

You can verify a download against the published `.dmg.sha256`:

```bash
shasum -a 256 -c Loomscreen-x.y.z.dmg.sha256
```

## System permission prompts

macOS asks for each of these the first time the matching feature is used — none
are requested up front, and all are optional:

| Prompt | When it appears | Why |
|---|---|---|
| Desktop / Documents / Downloads folder access | Importing a video, web page, or scene stored there | Loomscreen reads wallpaper files from where you keep them; access is remembered via security-scoped bookmarks. |
| Location (while using) | Weather source set to **System location** | Drives the weather-reactive overlay. Choose **Manual location** or **Off** in Settings → Weather to avoid it. |
| System audio recording (Pro) | Enabling **Audio Response** | Lets audio-reactive scenes visualize what's playing. Lite never asks. |

## First-run onboarding

On first launch a short onboarding opens:

1. Pick a source — **Import a File** (video / web page; Pro also accepts scene folders), **Apple Aerials**, or drag & drop.
2. With multiple displays, apply to one display or **All Displays**.
3. Done — the display's management page opens for tuning.

You can skip it and configure displays manually from the Settings window, or
re-run it later from **Settings → About → Welcome Tour**. Steam Workshop setup
is separate and only appears when you open the Workshop page
(see [quick-start.md](quick-start.md#8-workshop-setup-pro)).

## Updates

Both editions check the GitHub Releases API at launch and whenever you open the
menu bar popover, throttled to 12 hours — no background polling. When a newer
version exists, two places say so and both open the same release page:

- an **Update** button in the menu bar popover, left of the on/off switch;
- a banner in **Settings → About**, where you can also **Check Now** or
  **Skip this version**.

Skipping a version there hides it in both places — they read the same check.
Lite and Pro ship in the same release, so the page you land on carries both DMGs
and you pick the one you're running.

Updating is a manual download-and-replace: drag the new **Loomscreen.app** into
`/Applications` and repeat the `xattr` step once. No build auto-installs updates.

## Something wrong?

See [troubleshooting.md](troubleshooting.md) — it covers the "damaged app"
message, blank wallpapers, pause behavior, and Workshop issues.
