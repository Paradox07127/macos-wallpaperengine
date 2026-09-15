#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${INTERACTION_PROBE_OUT:?}"
python3 tools/interaction-state-probe/prepare.py
CORE=/private/tmp/lw-ui-settings-core
xcrun swiftc -O -g -swift-version 6 -target arm64-apple-macosx26.0 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation,ProjectSettingWidgets,InspectorResizeHandle,InspectorSplit}.swift \
 LiveWallpaper/Views/Schedule/{TimelineEditor,Preset}.swift LiveWallpaper/Policies/SchedulePolicy.swift \
 tools/ui-architecture-probe/NativeSlider.swift "$INTERACTION_PROBE_OUT"/generated/*.swift \
 tools/interaction-state-probe/{NativeResizeEvents,WebBoundary,main}.swift -o "$INTERACTION_PROBE_OUT/InteractionProbe" > "$INTERACTION_PROBE_OUT/build.log" 2>&1
APP="$INTERACTION_PROBE_OUT/InteractionProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$INTERACTION_PROBE_OUT/InteractionProbe" "$APP/Contents/MacOS/InteractionProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>InteractionProbe</string><key>CFBundleIdentifier</key><string>com.loomscreen.interaction-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun dwarfdump --uuid "$INTERACTION_PROBE_OUT/InteractionProbe" > "$INTERACTION_PROBE_OUT/binary-uuid.txt"
shasum -a 256 "$INTERACTION_PROBE_OUT/InteractionProbe" > "$INTERACTION_PROBE_OUT/binary-sha256.txt"
