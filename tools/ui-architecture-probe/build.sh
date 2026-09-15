#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${UI_PROBE_OUT:-$PWD/.notes/evidence/ui/2026-09-15-appkit-experiment}"
CORE="${UI_CORE_BUILD:-/private/tmp/lw-ui-core-4175}"
python3 tools/ui-architecture-probe/prepare.py
swift build --package-path Packages/LiveWallpaperCore -c release --scratch-path "$CORE" > "$OUT/core-build.log" 2>&1
xcrun swiftc -O -g -swift-version 6 -target arm64-apple-macosx14.6 -I "$CORE/release" \
 "$CORE"/release/LiveWallpaperCore.o \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation,ProjectSettingWidgets,ScenePreview}.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety/WPEPathSafety.swift \
 Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPEOrigin+Behavior.swift \
 LiveWallpaper/Views/Workshop/{BrowseCard,AnimatedGIFThumbnail,GIFCoordinator,WorkshopByteFormatter,WorkshopTagLocalization}.swift \
 LiveWallpaper/Infrastructure/Workshop/{WorkshopAnimatedGIF,WorkshopPreviewDiskCache,WorkshopDiskCacheStore,WorkshopCDNHostAllowList}.swift \
 LiveWallpaper/Infrastructure/Services/{PreviewWorkGate,BoundedNetworkFetch}.swift \
 LiveWallpaper/Infrastructure/Diagnostics/PreviewSignpost.swift \
 "$OUT"/generated/*.swift tools/ui-architecture-probe/{NativeSlider,ProbeViews,StateSequence,main}.swift \
 -o "$OUT/UIArchitectureProbe" > "$OUT/build.log" 2>&1
xcrun dwarfdump --uuid "$OUT/UIArchitectureProbe" > "$OUT/binary-uuid.txt"
shasum -a 256 "$OUT/UIArchitectureProbe" > "$OUT/binary-sha256.txt"

APP="$OUT/UIArchitectureProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/UIArchitectureProbe" "$APP/Contents/MacOS/UIArchitectureProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>UIArchitectureProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.ui-probe</string><key>CFBundleName</key><string>UIArchitectureProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" LiveWallpaper/Resources/Localizable.xcstrings > "$OUT/localization-build.log" 2>&1
