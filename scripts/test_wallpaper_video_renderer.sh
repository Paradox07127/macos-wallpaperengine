#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loomscreen-video-renderer-checks.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$ROOT"

# The extension in the fixture must share the production file to access its private lifecycle state.
cat SystemWallpaperProvider/VideoRenderer.swift \
  SystemWallpaperProviderTests/VideoRendererLifecycleChecks.swift > "$SCRATCH/VideoRendererChecks.swift"
ARCH="$(uname -m)"
xcrun swiftc -parse-as-library -swift-version 6 \
  -target "${ARCH}-apple-macos26.0" \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature MemberImportVisibility \
  -module-cache-path "$SCRATCH/ModuleCache" \
  "$SCRATCH/VideoRendererChecks.swift" SystemWallpaperProvider/StillFrameFactory.swift \
  -o "$SCRATCH/VideoRendererChecks"
python3 - "$SCRATCH/VideoRendererChecks" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=30, check=False)
except subprocess.TimeoutExpired:
    print("FAIL: VideoRenderer lifecycle checks exceeded 30 seconds", file=sys.stderr)
    sys.exit(1)
sys.exit(result.returncode)
PY
