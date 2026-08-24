#!/usr/bin/env bash
# Regenerate one SKU's Sparkle appcast from a released DMG.
#
# The appcast lists only the newest build. Sparkle only ever compares the user's
# version against the newest item, and listing history would mean keeping every
# past DMG on disk to re-sign it — GitHub Releases already is that history.
#
# Signing uses the EdDSA private key in the login keychain (generate_keys).
# Losing that key means no installed copy can ever be updated again, so it is
# backed up outside this repo; nothing here can regenerate it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="Paradox07127/macos-wallpaperengine"
TAG_PREFIX="loomscreen-v"

SKU=""; VERSION=""; DMG=""; BUILD=""; KEY_FILE=""; DERIVED_DATA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)         SKU="${2:-}"; shift 2 ;;
    --version)     VERSION="${2:-}"; shift 2 ;;
    --build)       BUILD="${2:-}"; shift 2 ;;
    --dmg)         DMG="${2:-}"; shift 2 ;;
    # For CI, where there is no keychain to prompt against. Locally the key
    # stays in the keychain and this stays unset.
    --ed-key-file) KEY_FILE="${2:-}"; shift 2 ;;
    # release-app.sh builds into its own derivedDataPath, not Xcode's default.
    --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done

case "$SKU" in
  pro)  APPCAST="$ROOT/appcast-pro.xml";  TITLE="Loomscreen Pro" ;;
  lite) APPCAST="$ROOT/appcast-lite.xml"; TITLE="Loomscreen" ;;
  *) echo "ERROR: --sku must be 'pro' or 'lite' (got: ${SKU:-<missing>})" >&2; exit 64 ;;
esac

[[ -n "$VERSION" ]] || { echo "ERROR: --version is required (e.g. 0.5.8)" >&2; exit 64; }
[[ -f "$DMG" ]] || { echo "ERROR: --dmg not found: ${DMG:-<missing>}" >&2; exit 66; }
# Sparkle compares sparkle:version to the running app's CFBundleVersion. Both
# SKUs set CFBundleVersion to MARKETING_VERSION, so --build must equal --version.
BUILD="${BUILD:-$VERSION}"
if [[ "$BUILD" != "$VERSION" ]]; then
  echo "ERROR: --build ($BUILD) must equal --version ($VERSION);" >&2
  echo "       Sparkle compares CFBundleVersion, which tracks MARKETING_VERSION." >&2
  exit 64
fi
if [[ -f "$APPCAST" ]]; then
  OLD_BUILD="$(sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' "$APPCAST" | head -1)"
  if [[ -n "$OLD_BUILD" && "$OLD_BUILD" != "$BUILD" ]]; then
    newest="$(printf '%s\n%s\n' "$OLD_BUILD" "$BUILD" | sort -V | tail -1)"
    if [[ "$newest" != "$BUILD" ]]; then
      echo "ERROR: sparkle:version $BUILD is not newer than $OLD_BUILD in $(basename "$APPCAST")" >&2
      exit 1
    fi
  fi
fi

# Ships with the SPM checkout rather than the repo, so resolve it instead of
# hardcoding a DerivedData path that differs per machine.
SEARCH_ROOTS=()
[[ -n "$DERIVED_DATA" ]] && SEARCH_ROOTS+=("$DERIVED_DATA")
SEARCH_ROOTS+=("$HOME/Library/Developer/Xcode/DerivedData")
SIGN_UPDATE=""
for root in "${SEARCH_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  SIGN_UPDATE="$(find "$root" -path "*artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)"
  [[ -n "$SIGN_UPDATE" ]] && break
done
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "ERROR: sign_update not found under: ${SEARCH_ROOTS[*]}" >&2
  echo "       Build the app once so SPM resolves Sparkle, or pass --derived-data." >&2
  exit 69
fi

echo "== Signing $(basename "$DMG") with the release EdDSA key =="
# Reading the private key out of the keychain raises an authorization dialog the
# first time a given build of sign_update asks. Unattended, that dialog would
# hang the release forever, so cap the wait and say exactly what to do.
SIGN_ARGS=("$DMG")
[[ -n "$KEY_FILE" ]] && SIGN_ARGS+=(--ed-key-file "$KEY_FILE")
# macOS ships no timeout(1), so run it in the background and reap it by hand.
SIGN_OUT="$(mktemp)"
trap 'rm -f "$SIGN_OUT"' EXIT
"$SIGN_UPDATE" "${SIGN_ARGS[@]}" >"$SIGN_OUT" 2>&1 &
SIGN_PID=$!
( sleep 60; kill -9 "$SIGN_PID" 2>/dev/null ) 2>/dev/null &
WATCHDOG_PID=$!
disown "$WATCHDOG_PID" 2>/dev/null || true
set +e
wait "$SIGN_PID"
SIGN_STATUS=$?
set -e
kill "$WATCHDOG_PID" 2>/dev/null || true
SIG_ATTRS="$(cat "$SIGN_OUT")"
# 137 = SIGKILL from the watchdog above.
if [[ $SIGN_STATUS -eq 137 ]]; then
  echo "ERROR: sign_update timed out after 60s." >&2
  echo "       A keychain authorization dialog is probably waiting. Run this once" >&2
  echo "       interactively and choose \"Always Allow\":" >&2
  echo "         $SIGN_UPDATE \"$DMG\"" >&2
  exit 75
fi
if [[ $SIGN_STATUS -ne 0 || "$SIG_ATTRS" != *edSignature=* ]]; then
  echo "ERROR: sign_update produced no signature: $SIG_ATTRS" >&2
  exit 1
fi

DMG_NAME="$(basename "$DMG")"
NOTES_URL="https://github.com/$REPO_SLUG/releases/tag/$TAG_PREFIX$VERSION"
# Sparkle clears com.apple.quarantine on what it installs (2.9.6 does it in
# Installer.xpc), but a DMG downloaded by hand from the releases page arrives
# quarantined and nothing here is notarized. The command therefore rides along in
# every update's notes instead of living only in a release body someone has to
# remember to write.
read -r -d '' DESCRIPTION <<HTML || true
<h2>$TITLE $VERSION</h2>
<p><strong>Gatekeeper:</strong> this build is code-signed but not notarized. If
you install the DMG by hand, clear the quarantine attribute once:</p>
<pre>xattr -dr com.apple.quarantine "/Applications/$TITLE.app"</pre>
<p>An update installed by $TITLE itself clears it for you.</p>
<p><a href="$NOTES_URL">Full release notes</a></p>
<hr>
<p><strong>Gatekeeper:</strong>本构建有签名但未经苹果公证。如果你是手动安装 DMG，请在终端执行一次：</p>
<pre>xattr -dr com.apple.quarantine "/Applications/$TITLE.app"</pre>
<p>通过 $TITLE 自动更新装上的版本已经替你清掉了。</p>
<p><a href="$NOTES_URL">完整发布说明</a></p>
HTML

URL="https://github.com/$REPO_SLUG/releases/download/$TAG_PREFIX$VERSION/$DMG_NAME"
PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
# Read the real deployment target rather than hardcoding one that can drift.
MIN_OS="$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$ROOT/LiveWallpaper.xcodeproj/project.pbxproj" \
  | sed 's/.*= *//; s/;.*//')"
if [[ -z "$MIN_OS" ]]; then
  echo "ERROR: could not read MACOSX_DEPLOYMENT_TARGET from the project" >&2
  exit 1
fi

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/generate-appcast.sh — do not hand-edit. -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$TITLE</title>
    <link>https://raw.githubusercontent.com/$REPO_SLUG/main/$(basename "$APPCAST")</link>
    <description>Updates for $TITLE</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:descriptionFormat="html"><![CDATA[
$DESCRIPTION
      ]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML

written="$(sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' "$APPCAST" | head -1)"
if [[ "$written" != "$BUILD" ]]; then
  echo "ERROR: wrote sparkle:version=$written, expected $BUILD" >&2
  exit 1
fi
if ! grep -q 'xattr -dr com.apple.quarantine' "$APPCAST"; then
  echo "ERROR: $APPCAST carries no quarantine instructions; the update dialog would omit them." >&2
  exit 1
fi
if ! xmllint --noout "$APPCAST" 2>/dev/null; then
  echo "ERROR: $APPCAST is not well-formed XML." >&2
  exit 1
fi

echo "  ✓ wrote $APPCAST"
echo "    enclosure: $URL"
echo
echo "  Commit it, create the GitHub release so the enclosure URL exists,"
echo "  then push to main — the app reads the feed from raw.githubusercontent.com."
