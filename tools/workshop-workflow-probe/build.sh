#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${UI_PROBE_OUT:?Set a new evidence directory}"
CORE="${UI_CORE_BUILD:-/private/tmp/lw-ui-settings-core}"
python3 tools/ui-architecture-probe/prepare.py
python3 tools/workshop-workflow-probe/prepare.py
swift build --package-path Packages/LiveWallpaperCore -c release --scratch-path "$CORE" > "$UI_PROBE_OUT/core-build.log" 2>&1
xcrun swiftc -O -g -swift-version 6 -target arm64-apple-macosx26.0 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation,ProjectSettingWidgets}.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety/WPEPathSafety.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPEOrigin+Behavior.swift \
 LiveWallpaper/Views/Workshop/{GIFCoordinator,WorkshopByteFormatter,WorkshopTagLocalization}.swift \
 LiveWallpaper/Infrastructure/Workshop/{WorkshopAnimatedGIF,WorkshopPreviewDiskCache,WorkshopDiskCacheStore,WorkshopCDNHostAllowList}.swift \
 LiveWallpaper/Infrastructure/Services/{PreviewWorkGate,BoundedNetworkFetch}.swift \
 LiveWallpaper/Infrastructure/Diagnostics/PreviewSignpost.swift \
 "$UI_PROBE_OUT"/generated/*.swift tools/workshop-workflow-probe/Views.swift "$UI_PROBE_OUT/driver/main.swift" \
 -o "$UI_PROBE_OUT/WorkflowProbe" > "$UI_PROBE_OUT/build.log" 2>&1
APP="$UI_PROBE_OUT/WorkflowProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UI_PROBE_OUT/WorkflowProbe" "$APP/Contents/MacOS/WorkflowProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>WorkflowProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.workflow-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" LiveWallpaper/Resources/Localizable.xcstrings > "$UI_PROBE_OUT/localization-build.log" 2>&1
codesign --force --sign - "$APP"
xcrun dwarfdump --uuid "$UI_PROBE_OUT/WorkflowProbe" > "$UI_PROBE_OUT/binary-uuid.txt"
shasum -a 256 "$UI_PROBE_OUT/WorkflowProbe" > "$UI_PROBE_OUT/binary-sha256.txt"
python3 tools/workshop-workflow-probe/manifest.py
