#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${GALLERY_PROBE_OUT:?}"
CORE=/private/tmp/lw-ui-settings-core
python3 tools/gallery-interaction-probe/prepare.py
swift build --package-path Packages/LiveWallpaperCore -c release --scratch-path "$CORE" > "$GALLERY_PROBE_OUT/core-build.log" 2>&1
xcrun swiftc -O -g ${GALLERY_EXTRA_FLAGS:-} -D LITE_BUILD -swift-version 6 -target arm64-apple-macosx26.0 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 LiveWallpaper/Infrastructure/Services/{PreviewWorkGate,WallpaperThumbnailService,HTMLSnapshotOwnership,PendingHTMLSnapshot}.swift \
 LiveWallpaper/Infrastructure/Persistence/WallpaperCoverStore.swift LiveWallpaper/Infrastructure/Diagnostics/PreviewSignpost.swift \
 LiveWallpaper/Views/{LibraryContentLocator,LibraryTileChrome}.swift \
 LiveWallpaper/Views/Aerials/ThumbnailCard.swift LiveWallpaper/Views/{Bookmarks/Presentation,Schemes/SchemePresentation}.swift \
 LiveWallpaper/Models/SystemWallpaperManifest.swift \
 "$GALLERY_PROBE_OUT/Extracted.swift" tools/gallery-interaction-probe/{Boundaries,InputChecks,main}.swift \
 -o "$GALLERY_PROBE_OUT/GalleryProbe" > "$GALLERY_PROBE_OUT/build.log" 2>&1
shasum -a 256 "$GALLERY_PROBE_OUT/GalleryProbe" > "$GALLERY_PROBE_OUT/binary-sha256.txt"
xcrun dwarfdump --uuid "$GALLERY_PROBE_OUT/GalleryProbe" > "$GALLERY_PROBE_OUT/binary-uuid.txt"
APP="$GALLERY_PROBE_OUT/GalleryProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$GALLERY_PROBE_OUT/GalleryProbe" "$APP/Contents/MacOS/GalleryProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>GalleryProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.gallery-probe</string><key>CFBundleName</key><string>GalleryProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" LiveWallpaper/Resources/Localizable.xcstrings > "$GALLERY_PROBE_OUT/localization-build.log" 2>&1
codesign --force --sign - "$APP" > "$GALLERY_PROBE_OUT/sign.log" 2>&1
