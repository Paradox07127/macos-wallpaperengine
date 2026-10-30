#!/usr/bin/env bash
#
# Build, sign, and package a release DMG for either SKU.
#
# Both SKUs ship signed with the team's Developer ID Application identity,
# notarized, and with tickets stapled to both the app and the DMG, so Gatekeeper opens a
# downloaded copy without a Terminal step. Manual signing keeps Xcode from
# picking an Apple Development certificate. The notary credentials come from a
# notarytool keychain profile (NOTARY_PROFILE, default loomscreen-notary).
#
# Usage:
#   scripts/release-app.sh --sku lite --version 0.2.0
#   scripts/release-app.sh --sku pro  --version 0.2.0 --dry-run
#   scripts/release-app.sh --sku pro  --version 0.2.0 --plan
#   scripts/release-app.sh --sku pro  --version 0.2.0 --skip-checks
#   scripts/release-app.sh --sku lite --version 0.9.0b1
#
# A --version with a bN suffix must match MARKETING_VERSION exactly, names its own
# artifacts, goes into the appcast's beta channel, and has to be published with
# `gh release create --prerelease`.
#
# Output (per SKU product name):
#   build/release/<Product>-X.Y.Z.dmg
#   build/release/<Product>-X.Y.Z.dmg.sha256
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKU="lite"
VERSION=""
DRY_RUN=0
PLAN=0
SKIP_CHECKS_FLAG=0
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)         SKU="${2:-}"; shift 2 ;;
    --version)     VERSION="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --plan)        PLAN=1; shift ;;
    --skip-checks) SKIP_CHECKS_FLAG=1; shift ;;
    # Passed straight to generate-appcast.sh so the update dialog carries this
    # version's changelog instead of only the quarantine line.
    --notes-file)  NOTES_FILE="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: --version is required (e.g. --version 0.2.0)" >&2
  exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?$ ]]; then
  echo "ERROR: --version must be major.minor.patch[bN] (got: $VERSION)" >&2
  exit 64
fi
if [[ -n "$NOTES_FILE" && ! -r "$NOTES_FILE" ]]; then
  echo "ERROR: --notes-file $NOTES_FILE does not exist or is not readable" >&2
  exit 64
fi
# A pre-release ships as its own artifact name and tag so it can never be mistaken for,
# or overwrite, the final build of the same version.
PRERELEASE=0
[[ "$VERSION" =~ b[0-9]+$ ]] && PRERELEASE=1

# Leave Lite's universal architectures to the project. Pro's archive override
# also keeps package dependencies and helpers from compiling unused Intel slices.
ARCHIVE_ARCHS=""
case "$SKU" in
  lite)
    SCHEME="LiveWallpaperLite"
    APP_NAME="Loomscreen"
    ARTIFACT="Loomscreen"
    VOLNAME="Loomscreen"
    BUNDLE_ID="com.loomscreen"
    DISPLAY_NAME="Loomscreen"
    ;;
  pro)
    ARCHIVE_ARCHS="arm64"
    SCHEME="LiveWallpaper"
    APP_NAME="Loomscreen Pro"
    ARTIFACT="Loomscreen-Pro"
    VOLNAME="Loomscreen Pro"
    BUNDLE_ID="com.loomscreen.pro"
    DISPLAY_NAME="Loomscreen Pro"
    ;;
  *)
    echo "ERROR: --sku must be 'lite' or 'pro' (got: $SKU)" >&2
    exit 64
    ;;
esac

DERIVED_DATA="${DERIVED_DATA:-${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/${ARTIFACT}Release}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
WPE_SHADER_TOOLCHAIN_ROOT="${WPE_SHADER_TOOLCHAIN_ROOT:-$ROOT/build/wpe-shader-toolchain-inputs}"
[[ "$WPE_SHADER_TOOLCHAIN_ROOT" == /* ]] || WPE_SHADER_TOOLCHAIN_ROOT="$ROOT/$WPE_SHADER_TOOLCHAIN_ROOT"

codesign_team_id() {
  codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier/{print $2; exit}'
}

# Code Sign on Copy re-signs Sparkle.framework's main binary with this app's
# Team ID but leaves Installer.xpc / Autoupdate / Updater.app ad-hoc. Sparkle's
# sandboxing docs require those helpers to be re-signed before distribution.
# Re-seal the outer app with --preserve-metadata so Xcode's processed sandbox
# entitlements stay — never pass a source .entitlements file.
resign_sparkle_helpers() {
  local app="$1"
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  local version_dir="$sparkle/Versions/B"
  if [[ ! -d "$sparkle" ]]; then
    echo "ERROR: Sparkle.framework missing from $app" >&2
    exit 1
  fi
  local identity="$SIGN_IDENTITY"
  if codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "ERROR: $app is not team-signed; Sparkle helpers cannot share a Team ID." >&2
    exit 1
  fi
  # Pull entitlements off the still-valid archive signature before nested
  # re-signing invalidates it. Passing a source .entitlements plist here would
  # drop the processed sandbox.
  local ent
  ent="$(mktemp -t loomscreen-sparkle-ent.XXXXXX)"
  # `set -e` exits mid-function on a failed codesign; expanded now because `ent` is local.
  trap "rm -f $(printf %q "$ent")" EXIT
  # `:-` writes XML to stdout. Bare `-` dumps a text blob codesign will not
  # accept back as `--entitlements`.
  codesign -d --entitlements :- --xml "$app" 2>/dev/null >"$ent"
  if ! grep -q 'com.apple.security.app-sandbox' "$ent"; then
    echo "ERROR: extracted entitlements from $app do not contain the App Sandbox." >&2
    rm -f "$ent"
    exit 1
  fi
  echo "  Re-signing Sparkle nested helpers as: $identity"
  local installer="$version_dir/XPCServices/Installer.xpc"
  local downloader="$version_dir/XPCServices/Downloader.xpc"
  local autoupdate="$version_dir/Autoupdate"
  local updater_app="$version_dir/Updater.app"
  [[ -d "$installer" ]] || { echo "ERROR: missing $installer" >&2; rm -f "$ent"; exit 1; }
  [[ -f "$autoupdate" ]] || { echo "ERROR: missing $autoupdate" >&2; rm -f "$ent"; exit 1; }
  [[ -d "$updater_app" ]] || { echo "ERROR: missing $updater_app" >&2; rm -f "$ent"; exit 1; }
  codesign -f -s "$identity" --timestamp -o runtime "$installer"
  if [[ -d "$downloader" ]]; then
    codesign -f -s "$identity" --timestamp -o runtime --preserve-metadata=entitlements "$downloader"
  fi
  codesign -f -s "$identity" --timestamp -o runtime "$autoupdate"
  codesign -f -s "$identity" --timestamp -o runtime "$updater_app"
  codesign -f -s "$identity" --timestamp -o runtime "$sparkle"
  codesign -f -s "$identity" --timestamp -o runtime --entitlements "$ent" "$app"
  rm -f "$ent"
  trap - EXIT

  local host_team
  host_team="$(codesign_team_id "$app")"
  if [[ -z "$host_team" || "$host_team" == "not set" ]]; then
    echo "ERROR: host TeamIdentifier is '${host_team:-empty}'; Sparkle needs a real Team ID." >&2
    exit 1
  fi
  local nested team
  for nested in "$installer" "$autoupdate" "$updater_app" "$sparkle"; do
    team="$(codesign_team_id "$nested")"
    if [[ "$team" != "$host_team" ]]; then
      echo "ERROR: $nested TeamIdentifier=$team, host is $host_team" >&2
      exit 1
    fi
  done
  if [[ -d "$downloader" ]]; then
    team="$(codesign_team_id "$downloader")"
    if [[ "$team" != "$host_team" ]]; then
      echo "ERROR: $downloader TeamIdentifier=$team, host is $host_team" >&2
      exit 1
    fi
  fi
  echo "  ✓ Sparkle helpers TeamIdentifier=$host_team"
}

# notarytool exits 0 for an Invalid verdict too; only status Accepted counts.
notarize() {
  local submission="$1" label="$2"
  local result="$OUTPUT_DIR/notary-$ARTIFACT-$label.json"
  xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$result" || true
  local status id
  status="$(plutil -extract status raw "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "ERROR: $label notarization status '${status:-unknown}' (submission ${id:-none})." >&2
    cat "$result" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
  fi
  echo "  ✓ $label notarized (submission $id)"
}

OUTPUT_DIR="$ROOT/build/release"
STAGING_DIR="$OUTPUT_DIR/staging-$ARTIFACT"
ARCHIVE_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.xcarchive"
APP_PATH="$STAGING_DIR/${APP_NAME}.app"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"
DMG_BG_PATH="$OUTPUT_DIR/dmg-bg-${ARTIFACT}.tiff"

if [[ "$PLAN" == "1" ]]; then
  echo "sku=$SKU"
  echo "scheme=$SCHEME"
  echo "app=$APP_NAME.app"
  echo "bundle_id=$BUNDLE_ID"
  echo "dmg=${ARTIFACT}-${VERSION}.dmg"
  echo "sha256=${ARTIFACT}-${VERSION}.dmg.sha256"
  exit 0
fi

if [[ "$SKU" == pro ]]; then
  WPE_SHADER_TOOLCHAIN_ROOT="$WPE_SHADER_TOOLCHAIN_ROOT" bash WPEShaderCompiler/build.sh --check-inputs
fi

mkdir -p "$OUTPUT_DIR"

echo "== [$SKU] Pre-flight: working tree =="
# Appcasts are produced at the end of each SKU. Allowing those two files to be
# dirty is what lets `lite` then `pro` run back-to-back; everything else still
# has to be committed first.
blocked_dirty=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    appcast-lite.xml|appcast-pro.xml) continue ;;
  esac
  blocked_dirty=1
  echo "  $path" >&2
done < <({ git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
if [[ "$blocked_dirty" == "1" ]]; then
  echo "ERROR: working tree has tracked or untracked changes (appcast-*.xml is allowed)." >&2
  git status -s >&2
  exit 65
fi

echo "== [$SKU] Pre-flight: MARKETING_VERSION matches --version =="
PROJECT_MARKETING_VERSION="$(xcodebuild -showBuildSettings \
    -project LiveWallpaper.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release 2>/dev/null \
  | awk -F'= ' '/^[[:space:]]*MARKETING_VERSION =/ {gsub(/[[:space:]]+$/,"",$2); print $2; exit}')"

if [[ "$PROJECT_MARKETING_VERSION" != "$VERSION" ]]; then
  echo "ERROR: --version ($VERSION) does not match $SCHEME MARKETING_VERSION ($PROJECT_MARKETING_VERSION)." >&2
  echo "       Bump MARKETING_VERSION in project.xcproj first, commit, then re-run." >&2
  exit 65
fi

# Local release checks attest the maintainer environment and run unless
# explicitly skipped.
SKIP_CHECKS=0
SKIP_REASON=""
if [[ "$DRY_RUN" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--dry-run"
elif [[ "$SKIP_CHECKS_FLAG" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--skip-checks (maintainer opt-out)"
fi

if [[ "$SKIP_CHECKS" == "1" ]]; then
  echo "== [$SKU] Pre-flight: skipping release-candidate checks ($SKIP_REASON) =="
else
  echo "== [$SKU] Pre-flight: release-candidate checks =="
  REQUIRE_DEVELOPER_ID=1 scripts/release_candidate_check.sh || {
    echo "ERROR: release_candidate_check.sh failed; fix before packaging." >&2
    exit 1
  }
fi

echo "== [$SKU] Cleaning previous artifacts =="
rm -rf "$ARCHIVE_PATH" "$STAGING_DIR" "$DMG_PATH" "$SHA_PATH" "$DMG_BG_PATH"

# Single source of truth: the project's own DEVELOPMENT_TEAM. check_entitlements.sh
# hardcodes the same value, so a mismatch fails the shipped-app audit below
# rather than producing a quietly wrong-signed build.
EXPECTED_TEAM_ID="$(grep -m1 '"DEVELOPMENT_TEAM": ' LiveWallpaper.xcodeproj/project.xcproj \
  | sed 's/.*: *"//; s/".*//')"
if [[ -z "$EXPECTED_TEAM_ID" ]]; then
  echo "ERROR: could not read DEVELOPMENT_TEAM from the project" >&2
  exit 1
fi
# Signing by SHA-1: two Developer ID certificates of one team share a name,
# and codesign rejects an ambiguous name.
DEVELOPER_ID_HASHES="$(security find-identity -v -p codesigning \
  | awk -v team="($EXPECTED_TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) {print $2}')"
if [[ "$(grep -c . <<<"$DEVELOPER_ID_HASHES")" != "1" ]]; then
  echo "ERROR: need exactly one Developer ID Application identity for team $EXPECTED_TEAM_ID; found:" >&2
  security find-identity -v -p codesigning | grep 'Developer ID Application' >&2 || true
  exit 1
fi
SIGN_IDENTITY="$DEVELOPER_ID_HASHES"

NOTARY_PROFILE="${NOTARY_PROFILE:-loomscreen-notary}"
if [[ "$DRY_RUN" != "1" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' is missing or rejected. Create it with:" >&2
  echo "       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $EXPECTED_TEAM_ID" >&2
  exit 1
fi

echo "== [$SKU] Archiving $SCHEME (Release, Developer ID $SIGN_IDENTITY, team $EXPECTED_TEAM_ID) =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  SWIFT_EMIT_LOC_STRINGS=NO \
  WPE_SHADER_TOOLCHAIN_ROOT="$WPE_SHADER_TOOLCHAIN_ROOT" \
  STRINGS_FILE_OUTPUT_ENCODING=binary \
  ${ARCHIVE_ARCHS:+ARCHS="$ARCHIVE_ARCHS"} \
  > "$OUTPUT_DIR/archive-$ARTIFACT.log" 2>&1 || {
    echo "ERROR: xcodebuild archive failed. Tail of log:" >&2
    tail -40 "$OUTPUT_DIR/archive-$ARTIFACT.log" >&2
    exit 1
  }

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: archive did not produce ${APP_NAME}.app at $ARCHIVED_APP" >&2
  exit 1
fi

echo "== [$SKU] Staging .app for packaging =="
mkdir -p "$STAGING_DIR"
ditto "$ARCHIVED_APP" "$APP_PATH"

if [[ -n "$ARCHIVE_ARCHS" ]]; then
  echo "== [$SKU] Thinning Sparkle to $ARCHIVE_ARCHS =="
  # Sparkle is a prebuilt universal binary, so ARCHS never thins it. Must run
  # before the re-sign below, which re-seals every binary changed here.
  SPARKLE_VERSION_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
  for sparkle_bin in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater \
      XPCServices/Downloader.xpc/Contents/MacOS/Downloader \
      XPCServices/Installer.xpc/Contents/MacOS/Installer; do
    lipo "$SPARKLE_VERSION_DIR/$sparkle_bin" -thin "$ARCHIVE_ARCHS" \
      -output "$SPARKLE_VERSION_DIR/$sparkle_bin"
  done
fi

echo "== [$SKU] Re-signing Sparkle nested helpers =="
# Code Sign on Copy re-signs Sparkle.framework's main binary with this app's
# Team ID but leaves Installer.xpc / Autoupdate / Updater.app ad-hoc. Sparkle's
# sandboxing docs require those helpers to be re-signed before distribution.
# Re-seal the outer app with --preserve-metadata so Xcode's processed sandbox
# entitlements stay — never pass a source .entitlements file.
resign_sparkle_helpers "$APP_PATH"

echo "== [$SKU] Verifying signature =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5

echo "== [$SKU] Entitlement baseline (shipped app) =="
# Validate the archive's effective entitlements, not only the source plist.
scripts/check_entitlements.sh --sku "$SKU" --app "$APP_PATH"

echo "== [$SKU] Bundle identity check =="
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_BUNDLE_VERSION="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"

if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "ERROR: Bundle ID expected $BUNDLE_ID, got $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "ERROR: CFBundleShortVersionString $ACTUAL_VERSION != $VERSION" >&2
  exit 1
fi
if [[ "$ACTUAL_BUNDLE_VERSION" != "$VERSION" ]]; then
  echo "ERROR: CFBundleVersion ($ACTUAL_BUNDLE_VERSION) must equal marketing version ($VERSION) so Sparkle treats each release as newer." >&2
  exit 1
fi
if [[ "$ACTUAL_DISPLAY_NAME" != "$DISPLAY_NAME" ]]; then
  echo "ERROR: CFBundleDisplayName expected $DISPLAY_NAME, got $ACTUAL_DISPLAY_NAME" >&2
  exit 1
fi
echo "  ✓ Bundle ID:        $ACTUAL_BUNDLE_ID"
echo "  ✓ DisplayName:      $ACTUAL_DISPLAY_NAME"
echo "  ✓ Short version:    $ACTUAL_VERSION"
echo "  ✓ Bundle version:   $ACTUAL_BUNDLE_VERSION"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== [$SKU] Dry run complete — skipping DMG generation =="
  echo "  Staged app: $APP_PATH"
  echo "  Archive:    $ARCHIVE_PATH"
  exit 0
fi

echo "== [$SKU] Notarizing app =="
# The app carries its own ticket so a copy dragged out of the DMG passes
# Gatekeeper offline.
APP_ZIP="$OUTPUT_DIR/${ARTIFACT}-notarize.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP" app
rm -f "$APP_ZIP"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "== [$SKU] Rendering DMG background =="
# Import the window/icon geometry from the renderer rather than repeating it, so
# the background image and Finder's icon placement cannot drift apart. Assign
# first, then eval: `eval "$(cmd)"` would swallow a failing cmd's exit status.
DMG_LAYOUT="$(swift "$ROOT/scripts/dmg_background.swift" --print-layout)" || {
  echo "ERROR: could not read the DMG layout." >&2
  exit 1
}
eval "$DMG_LAYOUT"
[[ -n "${DMG_WINDOW_W:-}" && -n "${DMG_APPS_Y:-}" ]] || {
  echo "ERROR: DMG layout import produced no values." >&2
  exit 1
}

swift "$ROOT/scripts/dmg_background.swift" "$DMG_BG_PATH" || {
  echo "ERROR: could not render the DMG background." >&2
  exit 1
}

echo "== [$SKU] Creating DMG =="
if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "ERROR: dmgbuild not found. Activate the release-tools environment from docs/en/releasing.md." >&2
  exit 1
fi
# Write the Finder layout directly without requiring a running Finder instance.
dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
  -D "staging=$STAGING_DIR" \
  -D "app_name=$APP_NAME" \
  -D "background=$DMG_BG_PATH" \
  -D "layout=$DMG_LAYOUT" \
  "$VOLNAME" "$DMG_PATH" \
  > "$OUTPUT_DIR/dmg-$ARTIFACT.log" 2>&1 || {
    echo "ERROR: dmgbuild failed. Tail of log:" >&2
    tail -20 "$OUTPUT_DIR/dmg-$ARTIFACT.log" >&2
    exit 1
  }

echo "== [$SKU] Signing and notarizing DMG =="
codesign -s "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
notarize "$DMG_PATH" dmg
# Stapling rewrites the DMG, so it must precede the checksum and the Sparkle signature below.
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "== [$SKU] Verifying DMG =="
# Verify the packaged app before publishing its checksum.
DMG_MOUNT="$(mktemp -d -t lw-dmg-verify)"
if ! hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$DMG_MOUNT" >/dev/null 2>&1; then
  echo "ERROR: could not mount $DMG_PATH for verification." >&2
  rmdir "$DMG_MOUNT" 2>/dev/null || true
  exit 1
fi
DMG_VERIFY_LOG="$(mktemp -t lw-dmg-verify.XXXXXX)"
if codesign --verify --deep --strict "$DMG_MOUNT/${APP_NAME}.app" 2>"$DMG_VERIFY_LOG" \
    && spctl --assess --type execute --verbose=2 "$DMG_MOUNT/${APP_NAME}.app" 2>>"$DMG_VERIFY_LOG" \
    && xcrun stapler validate "$DMG_MOUNT/${APP_NAME}.app" >>"$DMG_VERIFY_LOG" 2>&1; then
  echo "  ✓ DMG mounts; ${APP_NAME}.app verifies and Gatekeeper accepts it"
  grep 'source=' "$DMG_VERIFY_LOG" || true
  DMG_OK=1
else
  echo "ERROR: ${APP_NAME}.app inside the DMG failed signature or Gatekeeper verification:" >&2
  cat "$DMG_VERIFY_LOG" >&2
  DMG_OK=0
fi
hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
rmdir "$DMG_MOUNT" 2>/dev/null || true
rm -f "$DMG_VERIFY_LOG"
[[ "$DMG_OK" == "1" ]] || exit 1

echo "== [$SKU] Computing SHA-256 =="
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG_PATH##*/}"
) | tee "$SHA_PATH"

echo "== [$SKU] Regenerating Sparkle appcast =="
# The appcast is what installed copies actually read; a release whose DMG ships
# without a matching appcast entry reaches nobody. Pre-releases go to the beta
# channel, which only copies opted into beta updates read.
APPCAST_CHANNEL_ARGS=(--channel stable)
[[ "$PRERELEASE" == "1" ]] && APPCAST_CHANNEL_ARGS=(--channel beta)
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
scripts/generate-appcast.sh \
  --sku "$SKU" \
  "${APPCAST_CHANNEL_ARGS[@]}" \
  --version "$VERSION" \
  --build "$BUILD_NUMBER" \
  --dmg "$DMG_PATH" \
  --derived-data "$DERIVED_DATA" \
  ${NOTES_FILE:+--notes-file "$NOTES_FILE"}

DMG_SIZE_MB=$(( $(stat -f%z "$DMG_PATH") / 1024 / 1024 ))

echo
echo "============================================================"
echo "  ✅ $DISPLAY_NAME $VERSION packaged ($SKU)"
echo "============================================================"
echo "  DMG:      $DMG_PATH"
echo "  Size:     ${DMG_SIZE_MB} MB"
echo "  SHA-256:  $SHA_PATH"
if [[ "$PRERELEASE" == "1" ]]; then
  echo "  Tag:      loomscreen-v${VERSION} — publish with 'gh release create --prerelease'"
  echo "  Appcast:  appcast-${SKU}.xml beta channel — commit both SKUs' appcasts, create"
  echo "            the GitHub release so the enclosure exists, then push to main."
else
  echo "  Tag:      loomscreen-v${VERSION} (unified release; attach both SKUs)"
  echo "  Appcast:  appcast-${SKU}.xml — commit both SKUs' appcasts, create the"
  echo "            GitHub release so the enclosure exists, then push to main."
fi
echo "============================================================"
