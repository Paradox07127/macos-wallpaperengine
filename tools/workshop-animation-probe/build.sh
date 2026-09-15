#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ANIMATION_PROBE_OUT:?}"
UI_PROBE_OUT="$ANIMATION_PROBE_OUT" python3 tools/ui-architecture-probe/prepare.py
ANIMATION_PROBE_OUT="$ANIMATION_PROBE_OUT" python3 tools/workshop-animation-probe/prepare.py
CORE=/private/tmp/lw-ui-settings-core
xcrun swiftc -O -g -swift-version 6 -target arm64-apple-macosx26.0 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation,ProjectSettingWidgets}.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety/WPEPathSafety.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPEOrigin+Behavior.swift \
 LiveWallpaper/Views/Workshop/{BrowseCard,GIFCoordinator,WorkshopByteFormatter,WorkshopTagLocalization}.swift \
 LiveWallpaper/Infrastructure/Workshop/{WorkshopAnimatedGIF,WorkshopPreviewDiskCache,WorkshopDiskCacheStore,WorkshopCDNHostAllowList}.swift \
 LiveWallpaper/Infrastructure/Services/{PreviewWorkGate,BoundedNetworkFetch}.swift \
 LiveWallpaper/Infrastructure/Diagnostics/PreviewSignpost.swift \
 "$ANIMATION_PROBE_OUT"/generated/*.swift tools/workshop-animation-probe/main.swift -o "$ANIMATION_PROBE_OUT/AnimationProbe" > "$ANIMATION_PROBE_OUT/build.log" 2>&1
APP="$ANIMATION_PROBE_OUT/AnimationProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ANIMATION_PROBE_OUT/AnimationProbe" "$APP/Contents/MacOS/AnimationProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>AnimationProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.animation-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun dwarfdump --uuid "$ANIMATION_PROBE_OUT/AnimationProbe" > "$ANIMATION_PROBE_OUT/binary-uuid.txt"
shasum -a 256 "$ANIMATION_PROBE_OUT/AnimationProbe" > "$ANIMATION_PROBE_OUT/binary-sha256.txt"
