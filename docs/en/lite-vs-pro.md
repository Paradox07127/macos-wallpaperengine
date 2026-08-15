# Lite vs Pro

**English** · [简体中文](../zh-Hans/lite-vs-pro.md)

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
| Update check (notification only — never auto-installs) | ✅ | ✅ |
| **Wallpaper Engine scene rendering** (Metal) | — | ✅ |
| **Scene project import** (linked local folders, read in place) | — | ✅ |
| **Steam Workshop browse & download** | — | ✅ |
| **Scene presets** (Workshop presets + your own saved values) | — | ✅ |
| **Audio-reactive scenes** (system audio capture) | — | ✅ |
| **Adaptive frame rate under occlusion** | — | ✅ |
| **Per-display render threads** | — | ✅ |
| **Storage management** (projects, engine assets, caches) | — | ✅ |
| **Runs on Intel Macs** | ⚠️ untested | — |

## How the split is implemented

Pro-only code is gated with `#if !LITE_BUILD`. The Lite scheme
(`LiveWallpaperLite`) sets the `LITE_BUILD` compilation condition, so the whole
Wallpaper Engine renderer, scene runtime, and Workshop stack are compiled out of
the Lite binary entirely — they aren't merely hidden. Metal shader effects exist
only *inside* scene rendering (GLSL transpiled to Metal at load), so they are
part of the scene capability rather than a separate line item.

The runtime source of truth for what an edition exposes is
[`ProductCapabilities.swift`](../../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

The GitHub Releases update check runs in both editions. It compares against the
release tag rather than an asset name, so the single release that carries both
DMGs serves both. Neither edition installs anything — the banner only opens the
release page.

## Architecture

Lite ships as a universal binary (arm64 + x86_64), so it can run on the Intel Macs
that reach macOS 14.6. **The Intel slice has never been tested on Intel hardware** —
it compiles and links, and the hardware-sampling code paths (SMC sensor keys, the
`IOAccelerator` GPU statistics, `hw.perflevel*` core clusters) all carry Intel
fallbacks, but nobody has run it on an actual Intel Mac. The most likely symptom of
a gap is blank readings in the monitor board rather than a crash. Reports are welcome.

Pro is arm64-only. Its Metal scene renderer has never been exercised on Intel GPUs,
and shipping an untested renderer is a different order of risk from shipping an
untested widget.

## Licensing

- **Lite** is MIT and distributed here on GitHub Releases.
- **Pro** is the full edition. The MIT [`LICENSE`](../../LICENSE) covers the entire
  repository, including the Pro-only modules.
