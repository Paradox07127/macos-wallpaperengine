#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loomscreen-selected-persistence.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$ROOT"
xcrun swiftc -parse-as-library -swift-version 6 \
  LiveWallpaper/Models/SystemWallpaperManifest.swift LiveWallpaper/Models/SystemWallpaperPreparationOptions.swift \
  SystemWallpaperProviderTests/SelectedWallpaperPersistenceChecks.swift -o "$SCRATCH/checks"
"$SCRATCH/checks"
