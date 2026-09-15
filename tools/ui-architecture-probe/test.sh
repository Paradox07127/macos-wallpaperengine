#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/.notes/evidence/ui/2026-09-15-appkit-experiment"
CORE="${UI_CORE_BUILD:-/private/tmp/lw-ui-core-4175}"
TEST="$OUT/ProbeBehaviorTests.xctest"
mkdir -p "$TEST/Contents/MacOS"
xcrun swiftc -O -swift-version 6 -emit-library -module-name ProbeBehaviorTests -target arm64-apple-macosx14.6 \
 -I "$CORE/release" "$CORE/release/LiveWallpaperCore.o" \
 -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
 -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
 -L /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -lXCTestSwiftSupport -framework XCTest -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
 LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift \
 LiveWallpaper/Views/ScreenDetail/{PropertyValueLogic,ProjectPresentation}.swift \
 LiveWallpaper/Views/Workshop/GIFCoordinator.swift \
 tools/ui-architecture-probe/{NativeSlider,BehaviorTests}.swift \
 -o "$TEST/Contents/MacOS/ProbeBehaviorTests" > "$OUT/test-build.log" 2>&1
xcrun xctest "$TEST" > "$OUT/behavior-tests.log" 2>&1
