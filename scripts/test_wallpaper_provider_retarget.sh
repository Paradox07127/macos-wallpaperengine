#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loomscreen-provider-retarget.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$ROOT"
# Every provider source but the ExtensionKit entry point; LITE_BUILD keeps scenes out of the renderer.
sources=()
for file in SystemWallpaperProvider/*.swift; do
  [[ "$file" == SystemWallpaperProvider/SystemWallpaperProvider.swift ]] || sources+=("$file")
done
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos26.0" -D LITE_BUILD \
  -module-cache-path "$SCRATCH/ModuleCache" \
  "${sources[@]}" \
  LiveWallpaper/Models/SystemWallpaperManifest.swift LiveWallpaper/Models/SystemWallpaperPreparationOptions.swift \
  LiveWallpaper/Models/SystemWallpaperPlaybackPolicy.swift LiveWallpaper/Infrastructure/Platform/UserPresenceProbe.swift \
  SystemWallpaperProviderTests/ProviderRetargetChecks.swift -o "$SCRATCH/checks"
"$SCRATCH/checks"
