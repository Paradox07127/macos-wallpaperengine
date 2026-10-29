# Privacy Policy

[简体中文](../zh-Hans/privacy.md)

Last updated: 2026-10-29

This policy covers Loomscreen, Loomscreen Pro and the Mac App Store edition of Loomscreen.

## Summary

- Loomscreen has no account, no ads and no third-party analytics or tracking SDK.
- Your library, settings and wallpaper files stay on your Mac.
- The app contacts a network service only for a feature you use, and only with the data that feature needs.

## Data that stays on your Mac

- Wallpaper library, playlists, schedules and display settings.
- Access to folders you choose, stored as macOS security-scoped bookmarks.
- Pro: your Steam Web API key, stored in the macOS keychain.
- Pro audio response: system audio is analyzed on-device. It is not recorded, saved or sent anywhere.

## Features that use the network

| Feature | Service | What is sent |
|---|---|---|
| Weather effects with System or Manual location | Open-Meteo | Latitude and longitude rounded to about 1 km; Manual uses the selected city's coordinates |
| Now Playing artwork | iTunes Search API, Spotify oEmbed | Track title, artist and album, or the Spotify track link |
| Now Playing lyrics (off by default) | LRCLIB | Track title, artist, album and duration |
| Web wallpapers | The sites you add | Ordinary web requests from the page |
| Workshop (Pro) | Steam | Search terms, item IDs and your API key |
| Update checks (DMG editions) | Loomscreen update feed | Edition and version; with "Share anonymous hardware info" turned on, also Mac model, CPU, memory, macOS version and display count and resolution class |

The update feed counts checks by edition and version. It does not store IP addresses. The Mac App Store edition does not use this feed; the App Store delivers its updates.

Location access is used only for weather. You can choose a manual city instead, or turn weather off.

Open-Meteo receives the request's IP address and may retain request logs containing coordinates for up to 90 days under its [privacy terms](https://open-meteo.com/en/terms). Manual city search sends your search text to Apple Maps.

## Mac App Store edition

The Store edition has no Now Playing artwork or lyrics requests, Workshop access, system audio capture or Sparkle update checks. Its optional online features are weather and the web pages you choose. Settings and file permissions are stored separately from the DMG editions.

## Bug reports

**Report a Bug** lets you review a diagnostic preview in the app. Continuing opens a prefilled GitHub issue in your browser and sends that prefilled text to GitHub. The issue becomes public only when you submit it there. Local logs are not uploaded automatically; attaching them is your choice.

## Keeping and deleting your data

- Loomscreen has no server copy of your data. Data on your Mac stays until you delete it.
- **Settings › Advanced › Reset All Settings** clears the library, settings and folder access. Wallpaper files on disk are not deleted.
- Deleting the app and its container removes everything it stored. Pro: forget the Steam Web API key in the app, or delete it in Keychain Access.
- To stop location use, turn weather off, choose a manual city, or turn off Loomscreen in System Settings › Privacy & Security › Location Services.
- A GitHub issue you submitted can be edited or deleted on GitHub. To ask for removal, open an issue or contact the maintainer there.

## Children

Loomscreen does not request ages or child profiles. Optional network features follow the data practices above.

## Changes

Changes to this policy are published in this file, with a new date at the top.

## Contact

Open an issue at [GitHub Issues](https://github.com/Paradox07127/macos-wallpaperengine/issues).
