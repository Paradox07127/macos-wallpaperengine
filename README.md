# Loomscreen

<div align="center">

<img src="docs/images/loomscreen-logo.png" width="144" alt="Loomscreen" />

### Wallpaper Engine scenes on macOS — a native Metal renderer, plus video and web wallpapers across every display.

![macOS](https://img.shields.io/badge/macOS-14.6%2B-blue.svg)
![Architecture](https://img.shields.io/badge/Apple_Silicon-required_for_Pro-purple.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Release](https://img.shields.io/github/v/release/Paradox07127/macos-wallpaperengine?include_prereleases&sort=semver)

[⬇ Download](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest) ·
[🚀 Quick Start](docs/en/quick-start.md) ·
[✨ Features](docs/en/features.md) ·
[⚖ Lite vs Pro](docs/en/lite-vs-pro.md) ·
[🛠 Build](docs/en/building.md) ·
[🌐 中文](README.zh-Hans.md)

</div>

> An independent Metal implementation — not affiliated with Wallpaper Engine. Workshop downloads use your own Steam account and license.

![Loomscreen main UI](docs/images/main.png)

## Wallpaper types

| Type | Edition | What you get |
|---|---|---|
| **Wallpaper Engine scenes** | Pro | Native Metal renderer for `scene.pkg` projects — particles, shader effects, puppet-warp animation, audio-reactive layers, cursor effects. Import local project folders or download via Steam Workshop, including the presets its community publishes. |
| **Video** | Lite + Pro | `mp4` / `m4v` / `mov` / `avi`, smooth looping, HDR-aware color pipeline, per-display or spanned across all displays. |
| **Web pages** | Lite + Pro | Sandboxed `WKWebView` with JavaScript toggle, tracker blocking, custom CSS, and auto-refresh. |
| **Apple Aerials** | Lite + Pro | Browse and apply the Apple TV aerial videos already on your Mac. |

## In action

| | |
|:---:|:---:|
| ![Video wallpapers](docs/images/video.png) **Video** | ![Web wallpapers](docs/images/web.png) **Web** |
| ![Wallpaper Engine scenes](docs/images/scene.png) **Scenes (Pro)** | ![Steam Workshop](docs/images/workshop.png) **Workshop (Pro)** |

## More than a player

- **Per-display control** — every monitor runs its own wallpaper; copy one setup to all screens, or span a single video across them.
- **Playlists & scheduling** — shuffle, rotation intervals, time-of-day slots, and a bookmark library for one-click swaps.
- **Menu bar first** — global on/off, per-display play/pause and prev/next, plus a live CPU / GPU / RAM / thermal strip.
- **Overlays on any wallpaper** — nine particle effects (snow, rain, sakura, fireflies…), weather-reactive mode driven by live conditions, and a system-monitor board with CPU/GPU/network widgets and an AI-agent session tracker.
- **Laptop-friendly by default** — auto-pauses on full-screen apps, window occlusion, battery power, Low Power Mode, and per-app rules you define.
- **Global shortcuts** — seven bindable actions, from play/pause-all to reload.
- **Portable settings** — export/import your whole setup as a `.lwconfig` bundle.
- **Private by design** — no accounts, no telemetry.

## Editions

| | **Lite** | **Pro** |
|---|:---:|:---:|
| Video / Web / Apple Aerials, playlists, schedules, overlays, shortcuts | ✅ | ✅ |
| Wallpaper Engine scene rendering & import | — | ✅ |
| Steam Workshop browse & download | — | ✅ |
| Scene presets (Workshop presets + your own saved values) | — | ✅ |
| Audio-reactive scenes (system audio capture) | — | ✅ |
| Adaptive frame rate & per-display render threads | — | ✅ |
| Update check (notification only — never auto-installs) | ✅ | ✅ |

Lite is a lighter runtime, not a crippled UI — video, web, and Aerials fidelity is identical to Pro. Full matrix: [docs/en/lite-vs-pro.md](docs/en/lite-vs-pro.md).

## Install

1. Download the latest `Loomscreen-x.y.z.dmg` from [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest).
2. Drag **Loomscreen.app** into `/Applications`.
3. Clear the Gatekeeper quarantine once (the build is ad-hoc signed):
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch it — Loomscreen lives in your menu bar, and a short onboarding sets up your first wallpaper.

Details, permission prompts, and updates: [docs/en/install.md](docs/en/install.md) · First-run walkthrough: [docs/en/quick-start.md](docs/en/quick-start.md)

## Requirements

- macOS 14.6 or later
- **Loomscreen (Lite)**: Apple Silicon or Intel. The Intel slice is built and shipped but
  **has not been tested on an Intel Mac** — hardware readings in the monitor board are the
  most likely thing to come back empty. Reports welcome.
- **Loomscreen Pro**: Apple Silicon only. Its Metal scene renderer has never been run on
  Intel hardware.

## Build from source

```bash
git clone https://github.com/Paradox07127/macos-wallpaperengine.git
cd macos-wallpaperengine
open LiveWallpaper.xcodeproj
```

Schemes: `LiveWallpaperLite` (Lite) · `LiveWallpaper` (Pro). Requirements and test gates: [docs/en/building.md](docs/en/building.md).

## Contributing & license

Issues and PRs welcome — see [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for what every PR is asked to clear. Security issues go through [docs/SECURITY.md](docs/SECURITY.md), not the public tracker. For bug reports, use **Settings → About → Report a Bug…** in the app; it pre-fills diagnostics.

MIT ([LICENSE](LICENSE)) — the whole repository, including Pro-only modules.
