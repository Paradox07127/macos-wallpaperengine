#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loomscreen-selected-wallpaper.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$ROOT"
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos26.0" \
  SystemWallpaperProvider/SettingsProvider.swift SystemWallpaperProvider/SettingsShims.swift \
  SystemWallpaperProvider/SharedLibraryStore.swift SystemWallpaperProvider/LogPrivacy.swift \
  LiveWallpaper/Models/SystemWallpaperManifest.swift LiveWallpaper/Models/SystemWallpaperPreparationOptions.swift \
  SystemWallpaperProviderTests/SelectedWallpaperChecks.swift -o "$SCRATCH/SelectedWallpaperChecks"
"$SCRATCH/SelectedWallpaperChecks"
