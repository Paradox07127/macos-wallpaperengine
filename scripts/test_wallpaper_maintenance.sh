#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loomscreen-maintenance-checks.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$ROOT"

sources=(
  LiveWallpaper/Models/SystemWallpaperMaintenanceProtocol.swift
  WallpaperMaintenance/WallpaperMaintenanceEngine.swift
)
xcrun swiftc -swift-version 6 -module-cache-path "$SCRATCH/ModuleCache" \
  "${sources[@]}" WallpaperMaintenance/main.swift -o "$SCRATCH/WallpaperMaintenance"
xcrun swiftc -swift-version 6 -module-cache-path "$SCRATCH/ModuleCache" \
  "${sources[@]}" WallpaperMaintenanceTests/EngineChecks.swift -o "$SCRATCH/EngineChecks"
"$SCRATCH/EngineChecks"
