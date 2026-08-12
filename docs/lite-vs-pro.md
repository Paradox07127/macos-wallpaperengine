# Lite vs Pro

Both editions are built from one codebase. The split is **which renderers and
tools ship**, not which UI you get — Lite is a lightweight runtime, not a
stripped-down interface. Video / web / Apple Aerials fidelity is identical.

| Capability | Lite | Pro |
|---|:---:|:---:|
| Video wallpapers (incl. HDR color pipeline, span-all-displays) | ✅ | ✅ |
| Web wallpapers (JS toggle, tracker blocking, custom CSS, auto-refresh) | ✅ | ✅ |
| Apple Aerials | ✅ | ✅ |
| Per-display wallpapers, copy-to-all | ✅ | ✅ |
| Playlists, shuffle, rotation | ✅ | ✅ |
| Time-of-day schedule automation | ✅ | ✅ |
| Bookmarks | ✅ | ✅ |
| Particle & weather-reactive overlays | ✅ | ✅ |
| System-monitor overlay board | ✅ | ✅ |
| Global shortcuts | ✅ | ✅ |
| On-lock video-frame desktop-picture capture | ✅ | ✅ |
| Full-screen / occlusion / battery / Low Power Mode auto-pause | ✅ | ✅ |
| GitHub Releases update check | ✅ | — |
| **Wallpaper Engine scene rendering** (Metal) | — | ✅ |
| **Scene project import** (linked local folders, read in place) | — | ✅ |
| **Steam Workshop browse & download** | — | ✅ |
| **Audio-reactive scenes** (system audio capture) | — | ✅ |
| **Adaptive frame rate under occlusion** | — | ✅ |
| **Per-display render threads** | — | ✅ |
| **Storage management** (projects, engine assets, caches) | — | ✅ |

## How the split is implemented

Pro-only code is gated with `#if !LITE_BUILD`. The Lite scheme
(`LiveWallpaperLite`) sets the `LITE_BUILD` compilation condition, so the whole
Wallpaper Engine renderer, scene runtime, and Workshop stack are compiled out of
the Lite binary entirely — they aren't merely hidden. Metal shader effects exist
only *inside* scene rendering (GLSL transpiled to Metal at load), so they are
part of the scene capability rather than a separate line item.

The runtime source of truth for what an edition exposes is
[`ProductCapabilities.swift`](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

The GitHub Releases update check belongs to the public Lite build; Pro currently
has no in-app updater.

## Licensing

- **Lite** is MIT and distributed here on GitHub Releases.
- **Pro** is the full edition. The MIT [`LICENSE`](../LICENSE) covers the entire
  repository, including the Pro-only modules.
