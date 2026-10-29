#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/LiveWallpaperReleaseCandidateCheck}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR

# MAS is a separate shipping boundary; it needs neither the Pro shader SDK nor Sparkle.
if [[ "${1:-}" == "--appstore" ]]; then
  shift
  MAS_ARCHIVE="${ARCHIVE_PATH:-$DERIVED_DATA/LoomscreenAppStore.xcarchive}"
  case "$DERIVED_DATA" in
    /*) ;;
    *) echo "ERROR: DERIVED_DATA must be absolute." >&2; exit 64 ;;
  esac
  case "$DERIVED_DATA" in
    "$ROOT"|"$ROOT"/*) echo "ERROR: Keep DerivedData outside the repository." >&2; exit 64 ;;
  esac
  case "$MAS_ARCHIVE" in
    "$ROOT"|"$ROOT"/*) echo "ERROR: Keep the archive outside the repository." >&2; exit 64 ;;
    /*.xcarchive) ;;
    *) echo "ERROR: ARCHIVE_PATH must be an absolute .xcarchive path." >&2; exit 64 ;;
  esac
  [[ ! -e "$MAS_ARCHIVE" ]] || { echo "ERROR: Choose a fresh ARCHIVE_PATH." >&2; exit 64; }
  bash scripts/check_entitlements.sh --sku appstore --source
  I18N_GUARD_SCOPE=all bash scripts/i18n_guard.sh
  python3 scripts/check_localization_drift.py
  mkdir -p "$DERIVED_DATA"
  xcodebuild archive -project LiveWallpaper.xcodeproj -scheme LoomscreenAppStore \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" -archivePath "$MAS_ARCHIVE" \
    SWIFT_EMIT_LOC_STRINGS=NO "$@" >"$DERIVED_DATA/appstore-archive.log" 2>&1 || {
      tail -60 "$DERIVED_DATA/appstore-archive.log" >&2; exit 1;
    }
  python3 scripts/check_appstore_bundle.py "$MAS_ARCHIVE/Products/Applications/Loomscreen.app"
  echo "Archive: $MAS_ARCHIVE (local checks only; export and Apple validation still required)"
  exit 0
fi

WPE_SHADER_TOOLCHAIN_ROOT="${WPE_SHADER_TOOLCHAIN_ROOT:-$ROOT/build/wpe-shader-toolchain-inputs}"
[[ "$WPE_SHADER_TOOLCHAIN_ROOT" == /* ]] || WPE_SHADER_TOOLCHAIN_ROOT="$ROOT/$WPE_SHADER_TOOLCHAIN_ROOT"
export WPE_SHADER_TOOLCHAIN_ROOT
# The real rendering gate needs the compiler SDK, independently of any Workshop corpus.
bash WPEShaderCompiler/build.sh --check-inputs
MACOS_DESTINATION="platform=macOS,arch=arm64"
MACOS_ARCHIVE_DESTINATION="generic/platform=macOS"

if [[ "$DERIVED_DATA" != /* ]]; then
  echo "ERROR: DERIVED_DATA must be an absolute path outside the repository." >&2
  exit 64
fi
case "$DERIVED_DATA" in
  "$ROOT"|"$ROOT"/*)
    echo "ERROR: DERIVED_DATA must stay outside the repository." >&2
    exit 64
    ;;
esac

BUILD_SETTINGS_LOG="$(mktemp -t livewallpaper-release-build-settings.XXXXXX)"
MATRIX_BUILD_LOG="$(mktemp -t livewallpaper-link-matrix.XXXXXX)"
APP_TEST_RESULT_BUNDLE="${APP_TEST_RESULT_BUNDLE:-${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/LiveWallpaperReleaseCandidateTests-$$.xcresult}"
LITE_TEST_RESULT_BUNDLE="${LITE_TEST_RESULT_BUNDLE:-${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/LoomscreenLiteReleaseCandidateTests-$$.xcresult}"
# The link-matrix archives are throwaway — nothing downstream reads them
# (`release-app.sh` builds its own under build/release). They used to land on a
# fixed path and were never cleaned, so the second run of a dual-SKU release
# tripped `require_fresh_archive_path` on the first run's leftovers. A per-run
# directory makes "never validate a stale archive" true by construction instead
# of by check, and stops leaking an archive pair per run into /tmp.
ARCHIVE_SCRATCH="$(mktemp -d -t livewallpaper-rc-archives)"
trap 'rm -f "$BUILD_SETTINGS_LOG" "$MATRIX_BUILD_LOG"; rm -rf "$ARCHIVE_SCRATCH"' EXIT

fail_with_log() {
  local message="$1"
  echo "ERROR: $message Tail of log:" >&2
  tail -40 "$MATRIX_BUILD_LOG" >&2
  exit 1
}

# Pro links the system libc++ through its statically linked C++ text stack
# (HarfBuzz, msdfgen); Lite has no C++ and keeps the ban.
assert_no_libcxx_link() {
  local binary="$1"
  local label="$2"
  if otool -L "$binary" | grep -Eq 'libc\+\+'; then
    echo "ERROR: $label links libc++." >&2
    otool -L "$binary" >&2
    exit 1
  fi
}

# Debug can put the app code in a sibling dylib while the executable is only a launcher.
assert_lite_runtime_isolation() {
  local binary="$1" payload symbols dependencies
  local payloads=("$binary")
  if [[ -f "${binary}.debug.dylib" ]]; then
    payloads+=("${binary}.debug.dylib")
  fi
  for payload in "${payloads[@]}"; do
    # Capture completely before matching: grep -q can close a large nm pipe early,
    # making pipefail hide a forbidden symbol behind nm's SIGPIPE exit.
    if ! symbols="$(nm "$payload" 2>/dev/null)"; then
      echo "ERROR: Could not inspect Lite symbols: $payload" >&2
      exit 1
    fi
    if grep -E 'WPEMetalPresenter|WPEParitySceneDriver|WPEParityFrameRenderer|WPEParityScriptEngine' >/dev/null <<<"$symbols"; then
      echo "ERROR: Lite binary contains a Pro-only renderer symbol: $payload" >&2
      exit 1
    fi
    if ! dependencies="$(otool -L "$payload")"; then
      echo "ERROR: Could not inspect Lite dependencies: $payload" >&2
      exit 1
    fi
    if grep -E 'JavaScriptCore' >/dev/null <<<"$dependencies"; then
      echo "ERROR: Lite binary unexpectedly links JavaScriptCore: $payload" >&2
      exit 1
    fi
  done
}

require_fresh_archive_path() {
  local archive_path="$1"
  local label="$2"
  if [[ "$archive_path" != /* || "$archive_path" != *.xcarchive ]]; then
    echo "ERROR: $label archive path must be an absolute .xcarchive path." >&2
    exit 64
  fi
  case "$archive_path" in
    "$ROOT"|"$ROOT"/*)
      echo "ERROR: $label archive path must stay outside the repository." >&2
      exit 64
      ;;
  esac
  if [[ -e "$archive_path" ]]; then
    echo "ERROR: $label archive path already exists; choose a clean archive path." >&2
    exit 64
  fi
}

assert_arm64_binary() {
  local binary="$1"
  local label="$2"
  if [[ "$(lipo -archs "$binary")" != "arm64" ]]; then
    echo "ERROR: $label is not exactly arm64." >&2
    lipo -archs "$binary" >&2
    exit 1
  fi
}

# Both shipping Lite slices are required; Pro deliberately remains arm64-only.
assert_universal_binary() {
  local binary="$1"
  local label="$2"
  local archs
  archs="$(lipo -archs "$binary")"
  case "$archs" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *)
      echo "ERROR: $label must contain exactly arm64 and x86_64 (got: $archs)." >&2
      exit 1
      ;;
  esac
  echo "  ✓ $label architectures: $archs"
}


echo "== Entitlement source baseline =="
scripts/check_entitlements.sh --sku pro --source
scripts/check_entitlements.sh --sku lite --source

echo "== Release build settings =="
xcodebuild -showBuildSettings \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -destination "$MACOS_DESTINATION" \
  | tee "$BUILD_SETTINGS_LOG" \
  | grep -E "PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME|CODE_SIGN|DEVELOPMENT_TEAM|ENABLE_APP_SANDBOX|ENABLE_USER_SELECTED_FILES|ENTITLEMENTS"

if ! grep -q "ENABLE_HARDENED_RUNTIME = YES" "$BUILD_SETTINGS_LOG"; then
  echo "ERROR: Release Hardened Runtime is not enabled." >&2
  exit 1
fi

echo "== Privacy manifest =="
PRIVACY_MANIFEST="LiveWallpaper/PrivacyInfo.xcprivacy"
if [[ ! -f "$PRIVACY_MANIFEST" ]]; then
  echo "ERROR: Missing $PRIVACY_MANIFEST." >&2
  exit 1
fi
plutil -lint "$PRIVACY_MANIFEST"
plutil -extract NSPrivacyAccessedAPITypes raw -o - "$PRIVACY_MANIFEST" >/dev/null

if ! security find-identity -p codesigning -v | grep -q '"Developer ID Application:'; then
  if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    echo "ERROR: No Developer ID Application signing identity found on this Mac." >&2
    exit 1
  fi
  echo "WARNING: No Developer ID Application signing identity found on this Mac; notarized export must run on a signing machine." >&2
fi

# App schemes omit SwiftPM test products. Reuse Make's per-package exit/count gate.
echo "== Swift package tests (sequential) =="
bash scripts/app_tests.sh packages "$DERIVED_DATA/SwiftPM" LiveWallpaperCore LiveWallpaperProWPE

echo "== Unit tests (Pro scheme) =="
DERIVED_DATA="$DERIVED_DATA" \
RESULT_BUNDLE="$APP_TEST_RESULT_BUNDLE" \
scripts/app_tests.sh full

# The Pro host can only ever prove Pro's signature, so Lite's signed grants need
# their own host. Runs through the runner for the test-count and skipped-suite
# validation; a plain `xcodebuild test` would report green on an empty run.
echo "== Unit tests (Lite scheme) =="
python3 scripts/xcode_test_runner.py \
  --label "Lite SKU smoke" \
  --result-bundle "$LITE_TEST_RESULT_BUNDLE" \
  --minimum-test-count 3 \
  --require-suite LiteHostSmokeTests \
  -- \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Debug \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "${DERIVED_DATA}LiteTests" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  test \
  SWIFT_EMIT_LOC_STRINGS=NO

# Cover Pro and Lite Debug/Release links with isolated build databases.
# Developer ID entitlements and notarization remain a separate signing-machine gate.
PRO_DEBUG_BIN="$DERIVED_DATA/Build/Products/Debug/Loomscreen Pro.app/Contents/MacOS/Loomscreen Pro"
[[ -x "$PRO_DEBUG_BIN" ]] || fail_with_log "Pro Debug test action did not produce the app binary."

DERIVED_DATA_PRO_RELEASE="${DERIVED_DATA}ProRelease"
PRO_ARCHIVE_PATH="${PRO_ARCHIVE_PATH:-$ARCHIVE_SCRATCH/LiveWallpaper-LinkMatrix.xcarchive}"
require_fresh_archive_path "$PRO_ARCHIVE_PATH" "Pro Release"
echo "== Link matrix + archive smoke: Pro Release =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -destination "$MACOS_ARCHIVE_DESTINATION" \
  -archivePath "$PRO_ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PRO_RELEASE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64 \
  WPE_SHADER_TOOLCHAIN_ROOT="$WPE_SHADER_TOOLCHAIN_ROOT" \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaper Release archive failed."
PRO_ARCHIVED_APP="$PRO_ARCHIVE_PATH/Products/Applications/Loomscreen Pro.app"
PRO_RELEASE_BIN="$PRO_ARCHIVED_APP/Contents/MacOS/Loomscreen Pro"
python3 scripts/check_third_party_notices.py --app "$PRO_ARCHIVED_APP" --sku pro
[[ -x "$PRO_RELEASE_BIN" ]] || fail_with_log "Pro Release archive did not produce Loomscreen Pro.app."
assert_arm64_binary "$PRO_RELEASE_BIN" "Pro Release archive"
codesign --verify --deep --strict --verbose=2 "$PRO_ARCHIVED_APP"


DERIVED_DATA_LITE_DEBUG="${DERIVED_DATA}LiteDebug"
echo "== Link matrix: Lite Debug =="
xcodebuild build \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Debug \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_LITE_DEBUG" \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaperLite Debug build failed."
LITE_DEBUG_BIN="$DERIVED_DATA_LITE_DEBUG/Build/Products/Debug/Loomscreen.app/Contents/MacOS/Loomscreen"
[[ -x "$LITE_DEBUG_BIN" ]] || fail_with_log "Lite Debug build did not produce the app binary."
assert_no_libcxx_link "$LITE_DEBUG_BIN" "Lite Debug"

DERIVED_DATA_LITE_RELEASE="${DERIVED_DATA}LiteRelease"
LITE_ARCHIVE_PATH="${LITE_ARCHIVE_PATH:-$ARCHIVE_SCRATCH/Loomscreen-LinkMatrix.xcarchive}"
require_fresh_archive_path "$LITE_ARCHIVE_PATH" "Lite Release"
echo "== Link matrix + archive smoke: Lite Release =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Release \
  -destination "$MACOS_ARCHIVE_DESTINATION" \
  -archivePath "$LITE_ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_LITE_RELEASE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaperLite Release archive failed."

LITE_ARCHIVED_APP="$LITE_ARCHIVE_PATH/Products/Applications/Loomscreen.app"
LITE_RELEASE_BIN="$LITE_ARCHIVED_APP/Contents/MacOS/Loomscreen"
python3 scripts/check_third_party_notices.py --app "$LITE_ARCHIVED_APP" --sku lite
[[ -x "$LITE_RELEASE_BIN" ]] || fail_with_log "Lite Release archive did not produce Loomscreen.app."
assert_universal_binary "$LITE_RELEASE_BIN" "Lite Release archive"
assert_universal_binary "$LITE_ARCHIVED_APP/Contents/Extensions/SystemWallpaperProviderLite.appex/Contents/MacOS/SystemWallpaperProviderLite" "Lite system wallpaper extension"
assert_universal_binary "$LITE_ARCHIVED_APP/Contents/XPCServices/WallpaperMaintenance.xpc/Contents/MacOS/WallpaperMaintenance" "Lite WallpaperMaintenance service"
codesign --verify --deep --strict --verbose=2 "$LITE_ARCHIVED_APP"
assert_no_libcxx_link "$LITE_RELEASE_BIN" "Lite Release archive"

# Lite must remain free of Pro renderer and SceneScript components in every code payload.
for lite_binary in "$LITE_DEBUG_BIN" "$LITE_RELEASE_BIN"; do
  assert_lite_runtime_isolation "$lite_binary"
done
# Both SKUs ship WallpaperMaintenance, which runs lsregister/pkill for the system
# wallpaper extension outside the sandbox. Pro additionally ships SteamConnector,
# which runs SteamCMD outside the sandbox so downloads land in the user's real
# Steam library. Every embedded service must stay unsandboxed: a sandboxed
# SteamConnector would put its STEAMROOT back in the container and silently undo
# the migration, and a sandboxed WallpaperMaintenance could not reach lsregister.
# The SceneScript helper retired 2026-07-23 must never come back — it isolated
# only provably-inert scripts while the dynamic ones ran in-process.
assert_embedded_xpc_services() {
  local app="$1" expected="$2" actual service
  if [[ ! -d "$app/Contents/XPCServices" ]]; then
    echo "ERROR: $app is missing its Contents/XPCServices (expected: $expected)." >&2
    exit 1
  fi
  actual="$(ls "$app/Contents/XPCServices" | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $app unexpectedly embeds an XPC service. expected: $expected; found: $actual" >&2
    exit 1
  fi
  for service in $expected; do
    if codesign -d --entitlements - --xml \
        "$app/Contents/XPCServices/$service" 2>/dev/null \
        | plutil -p - 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
      echo "ERROR: $service in $app is sandboxed; its \$HOME would be the app container." >&2
      exit 1
    fi
  done
}
assert_embedded_xpc_services "$LITE_ARCHIVED_APP" "WallpaperMaintenance.xpc"
assert_embedded_xpc_services "$PRO_ARCHIVED_APP" "SteamConnector.xpc WallpaperMaintenance.xpc"
echo "  ✓ Pro/Lite Debug/Release links, embedded XPC services, and Lite archive purity verified"

echo "== Diff whitespace check =="
git diff --check

echo "Release candidate checks passed."
