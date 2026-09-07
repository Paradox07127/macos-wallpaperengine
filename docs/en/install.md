# Install & update

**English** · [简体中文](../zh-Hans/install.md)

## Install (DMG)

1. Download your edition from [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest):
   `Loomscreen-x.y.z.dmg` for Lite, or `Loomscreen-Pro-x.y.z.dmg` for Pro.
2. Open it and drag **Loomscreen.app** or **Loomscreen Pro.app** to `/Applications`.
3. Launch the app; it lives in the menu bar. Lite requires macOS 14.6+ and ships
   for Apple Silicon and Intel (Intel hardware remains untested). Pro requires Apple Silicon.

### If macOS refuses to open the download

Current public packages use **Apple Development signing**, not Developer ID
signing, and are **not notarized**. A manually downloaded copy may be blocked
by Gatekeeper. First compare the DMG with the published checksum, in the folder
containing both downloaded files:

```bash
shasum -a 256 -c Loomscreen-x.y.z.dmg.sha256
```

Use the Pro filename for its checksum. If the verified copy is still blocked,
clear quarantine on the installed app you chose:

```bash
xattr -dr com.apple.quarantine /Applications/Loomscreen.app
```

For Pro:

```bash
xattr -dr com.apple.quarantine "/Applications/Loomscreen Pro.app"
```

Reopen the app. This is a fallback for a trusted manual download, not a repair
for every launch failure. In-app Sparkle updates normally handle quarantine
during installation; a fresh manual download may require this step again.

## System permission prompts

Permissions depend on the feature and macOS's existing grants. Denying one can
leave that feature unavailable; it does not require enabling unrelated features.

| Permission | Used for |
|---|---|
| Files and folders / selected directory | Importing media, local web projects, scene folders, or authorizing a Steam library; bookmarks retain selected access |
| Location | Weather widgets and weather response with **System location**; choose manual location or Off instead |
| System audio recording (Pro) | Audio Response for scenes and music visual effects; Lite does not capture system audio |
| Automation: Spotify / Music | Playback control, seeking and reading a missing playhead for Now Playing; macOS may prompt when these operations first run |
| Keychain access | Saving or reading the Steam Web API key; a signing change or an existing item can require approval |

## First-run onboarding

Choose **Import a File**, **Apple Aerials**, or drag a supported file/project
into the app. With multiple displays, select one or all. You can skip onboarding
and configure displays in Settings, or reopen **About → Welcome Tour**.
Workshop setup is separate; see [Quick Start](quick-start.md#8-workshop-setup-pro).

## Updates

Both editions use **Sparkle**, with a separate HTTPS appcast for each edition.
Sparkle checks for updates and can show its update dialog. The menu-bar
**Update** button and **Settings → About** also open the update flow; Sparkle
can download, verify the signed payload, install and relaunch the app.

**Settings → General** controls automatic checking. Manual checking remains
available from About. Download/install/skip choices belong to Sparkle's dialog;
the menu-bar badge can remain while the current update session is retained.
Updates are not limited to opening a GitHub release page, and an enabled
check is not itself consent to install.

You can also download the matching edition's DMG and replace the app manually.
See [Troubleshooting](troubleshooting.md) for launch, permission or update problems.
