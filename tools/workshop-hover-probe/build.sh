#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${HOVER_PROBE_OUT:?}"
UI_PROBE_OUT="$HOVER_PROBE_OUT" python3 tools/ui-architecture-probe/prepare.py
HOVER_PROBE_OUT="$HOVER_PROBE_OUT" python3 tools/workshop-hover-probe/prepare.py
CORE=/private/tmp/lw-ui-settings-core
xcrun swiftc -O -g -swift-version 6 -target arm64-apple-macosx26.0 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation,ProjectSettingWidgets}.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety/WPEPathSafety.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPEOrigin+Behavior.swift \
 LiveWallpaper/Views/Workshop/{GIFCoordinator,WorkshopByteFormatter,WorkshopTagLocalization}.swift \
 LiveWallpaper/Infrastructure/Workshop/{WorkshopAnimatedGIF,WorkshopPreviewDiskCache,WorkshopDiskCacheStore,WorkshopCDNHostAllowList}.swift \
 LiveWallpaper/Infrastructure/Services/{PreviewWorkGate,BoundedNetworkFetch}.swift \
 LiveWallpaper/Infrastructure/Diagnostics/PreviewSignpost.swift \
 "$HOVER_PROBE_OUT"/generated/*.swift tools/workshop-hover-probe/main.swift -o "$HOVER_PROBE_OUT/HoverProbe" > "$HOVER_PROBE_OUT/build.log" 2>&1
APP="$HOVER_PROBE_OUT/HoverProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$HOVER_PROBE_OUT/HoverProbe" "$APP/Contents/MacOS/HoverProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>HoverProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.hover-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun dwarfdump --uuid "$HOVER_PROBE_OUT/HoverProbe" > "$HOVER_PROBE_OUT/binary-uuid.txt"
shasum -a 256 "$HOVER_PROBE_OUT/HoverProbe" > "$HOVER_PROBE_OUT/binary-sha256.txt"
