# Loomscreen Documentation

**English** · [简体中文](zh-Hans/README.md)

Loomscreen is a menu-bar-first macOS live wallpaper platform: Wallpaper Engine
scenes rendered natively with Metal (Pro), plus video, web, and Apple Aerials
wallpapers with per-display settings, saved schemes, playlists and automation.
Independent weather, widget and music overlays accompany the desktop; macOS
26+ also has a compatibility-gated system video wallpaper provider.

## For users

- [quick-start.md](en/quick-start.md) — first wallpaper to daily workflow, including Workshop setup and scene presets.
- [install.md](en/install.md) — install, permission prompts, and updates.
- [troubleshooting.md](en/troubleshooting.md) — common failures and fixes.
- [lite-vs-pro.md](en/lite-vs-pro.md) — edition capability matrix.

## For contributors

- [features.md](en/features.md) — current features and edition boundaries.
- [architecture.md](en/architecture.md) — app/session ownership, packages, rendering, XPC and the system provider.
- [building.md](en/building.md) — build requirements, schemes, and test gates.
- [releasing.md](en/releasing.md) — maintainer release checklist.
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to propose a change.
- [SECURITY.md](SECURITY.md) — reporting a vulnerability.
- [LiveWallpaperCore DESIGN.md](../Packages/LiveWallpaperCore/DESIGN.md) — shared UI tokens, components and accessibility rules.
- [../CHANGELOG.md](../CHANGELOG.md) — release history for Lite and Pro.

## Translations

Every page under `en/` has a counterpart under `zh-Hans/` with the same
filename. A change to one is expected to land in the other in the same PR.

## Support

- [GitHub Issues](https://github.com/Paradox07127/macos-wallpaperengine/issues) — include macOS version, Mac model, and reproduction steps, or use **Settings → About → Report a Bug…** in the app.
- [GitHub Discussions](https://github.com/Paradox07127/macos-wallpaperengine/discussions) — questions and ideas.
