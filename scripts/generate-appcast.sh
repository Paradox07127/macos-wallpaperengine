#!/usr/bin/env bash
# Regenerate one SKU's Sparkle appcast from a released DMG.
#
# Each channel lists only its newest build: one untagged item (Sparkle's default
# channel, stable) and at most one tagged <sparkle:channel>beta</sparkle:channel>.
# Sparkle only ever compares the user's version against the newest item it may
# see, and listing history would mean keeping every past DMG on disk to re-sign
# it — GitHub Releases already is that history.
#
# Signing uses the EdDSA private key in the login keychain (generate_keys).
# Losing that key means no installed copy can ever be updated again, so it is
# backed up outside this repo; nothing here can regenerate it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="Paradox07127/macos-wallpaperengine"
TAG_PREFIX="loomscreen-v"

SKU=""; VERSION=""; DMG=""; BUILD=""; KEY_FILE=""; DERIVED_DATA=""; NOTES_FILE=""; CHANNEL="stable"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)         SKU="${2:-}"; shift 2 ;;
    --channel)     CHANNEL="${2:-}"; shift 2 ;;
    --version)     VERSION="${2:-}"; shift 2 ;;
    --build)       BUILD="${2:-}"; shift 2 ;;
    --dmg)         DMG="${2:-}"; shift 2 ;;
    # For CI, where there is no keychain to prompt against. Locally the key
    # stays in the keychain and this stays unset.
    --ed-key-file) KEY_FILE="${2:-}"; shift 2 ;;
    # release-app.sh builds into its own derivedDataPath, not Xcode's default.
    --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
    # The release notes this version ships with, so the update dialog and the
    # GitHub release page say the same thing. Optional: without it the dialog
    # falls back to the quarantine line alone, which is what shipped before 0.6.2.
    --notes-file)  NOTES_FILE="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done

case "$SKU" in
  pro)  APPCAST="$ROOT/appcast-pro.xml";  TITLE="Loomscreen Pro"; APP_PLIST="$ROOT/LiveWallpaperInfo.plist" ;;
  lite) APPCAST="$ROOT/appcast-lite.xml"; TITLE="Loomscreen"; APP_PLIST="$ROOT/LoomscreenInfo.plist" ;;
  *) echo "ERROR: --sku must be 'pro' or 'lite' (got: ${SKU:-<missing>})" >&2; exit 64 ;;
esac

[[ -n "$VERSION" ]] || { echo "ERROR: --version is required (e.g. 0.5.8)" >&2; exit 64; }
# Sparkle's standard comparator ignores a `-beta.N` suffix; `bN` orders correctly.
case "$CHANNEL" in
  stable) VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$' ;;
  beta)   VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+b[0-9]+$' ;;
  *) echo "ERROR: --channel must be 'stable' or 'beta' (got: ${CHANNEL:-<missing>})" >&2; exit 64 ;;
esac
if [[ ! "$VERSION" =~ $VERSION_PATTERN ]]; then
  echo "ERROR: --version $VERSION does not fit the $CHANNEL channel (stable X.Y.Z, beta X.Y.ZbN)" >&2
  exit 64
fi
[[ -f "$DMG" ]] || { echo "ERROR: --dmg not found: ${DMG:-<missing>}" >&2; exit 66; }
# Sparkle compares sparkle:version to the running app's CFBundleVersion. Both
# SKUs set CFBundleVersion to MARKETING_VERSION, so --build must equal --version.
BUILD="${BUILD:-$VERSION}"
if [[ "$BUILD" != "$VERSION" ]]; then
  echo "ERROR: --build ($BUILD) must equal --version ($VERSION);" >&2
  echo "       Sparkle compares CFBundleVersion, which tracks MARKETING_VERSION." >&2
  exit 64
fi

# Succeeds when $1 orders after $2 the way Sparkle orders them: X.Y.Z numerically,
# then a release after any of its own bN builds, then bN by N.
version_gt() {
  local a_core="${1%%b*}" b_core="${2%%b*}" a_beta="" b_beta="" i
  [[ "$1" == *b* ]] && a_beta="${1##*b}"
  [[ "$2" == *b* ]] && b_beta="${2##*b}"
  local -a a_parts b_parts
  IFS=. read -r -a a_parts <<<"$a_core"
  IFS=. read -r -a b_parts <<<"$b_core"
  for i in 0 1 2; do
    (( 10#${a_parts[i]} > 10#${b_parts[i]} )) && return 0
    (( 10#${a_parts[i]} < 10#${b_parts[i]} )) && return 1
  done
  [[ -z "$a_beta" ]] && { [[ -n "$b_beta" ]]; return; }
  [[ -z "$b_beta" ]] && return 1
  (( 10#$a_beta > 10#$b_beta ))
}

# Prints the items of one channel verbatim; the file is this script's own output.
appcast_items() {
  local source="${2:-$APPCAST}"
  [[ -f "$source" ]] || return 0
  awk -v want="$1" '
    /<item>/ { buf = ""; inside = 1 }
    inside { buf = buf $0 "\n" }
    inside && /<\/item>/ {
      inside = 0
      is_beta = (buf ~ /<sparkle:channel>beta<\/sparkle:channel>/)
      if ((want == "beta") == is_beta) printf "%s", buf
    }
  ' "$source"
}

item_version() {
  sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' <<<"$1" | head -1
}

OLD_STABLE_ITEM="$(appcast_items stable)"
OLD_BETA_ITEM="$(appcast_items beta)"
OLD_STABLE="$(item_version "$OLD_STABLE_ITEM")"
OLD_BETA="$(item_version "$OLD_BETA_ITEM")"
if [[ "$CHANNEL" == "stable" ]]; then
  OLD_SAME="$OLD_STABLE"
else
  OLD_SAME="$OLD_BETA"
fi
# Rewriting the same version is allowed so a failed release can be rerun.
if [[ -n "$OLD_SAME" && "$OLD_SAME" != "$BUILD" ]] && ! version_gt "$BUILD" "$OLD_SAME"; then
  echo "ERROR: sparkle:version $BUILD is not newer than $OLD_SAME in $(basename "$APPCAST")" >&2
  exit 1
fi
if [[ "$CHANNEL" == "beta" && -n "$OLD_STABLE" ]] && ! version_gt "$BUILD" "$OLD_STABLE"; then
  echo "ERROR: beta $BUILD is not newer than stable $OLD_STABLE in $(basename "$APPCAST")" >&2
  exit 1
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
APPCAST_TMP=""
trap 'rm -f "$SIGN_OUT" "$APPCAST_TMP"' EXIT
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

# Check the exact archive independently against the public key shipped by this SKU,
# before writing an appcast. A successful signer alone does not establish key pairing.
xcrun swift "$ROOT/scripts/verify-sparkle-signature.swift" "$DMG" "$APP_PLIST" "$SIGN_OUT"

DMG_NAME="$(basename "$DMG")"
NOTES_URL="https://github.com/$REPO_SLUG/releases/tag/$TAG_PREFIX$VERSION"

# What changed, lifted from the same notes file the GitHub release body uses, so
# the two cannot drift. Only the English half (everything before the `---`) and
# only the three changelog sections: the download table is meaningless inside an
# updater that is already downloading, and the pane is 565x402 — 10975ac shipped
# a version whose two-language block opened scrolled past its own first half.
CHANGELOG_HTML=""
if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 66; }
  CHANGELOG_HTML="$(awk '
    /^---$/ { exit }                                  # stop at the language separator
    /^## (What'"'"'s New|Improvements|Bug Fixes)$/ {
      if (open) { print "</ul>" }
      sub(/^## /, ""); printf "<p><strong>%s</strong></p>\n<ul>\n", $0
      open = 1; next
    }
    /^## / { if (open) { print "</ul>"; open = 0 } next }   # any other section: drop
    open && /^- / {
      sub(/^- /, "")
      gsub(/&/, "\&amp;"); gsub(/</, "\&lt;"); gsub(/>/, "\&gt;")
      gsub(/\*\*/, "")                                    # bold markers do not survive as text
      gsub(/`/, "")
      printf "<li>%s</li>\n", $0
    }
    END { if (open) print "</ul>" }
  ' "$NOTES_FILE")"
fi

# Measured 2026-08-30: Sparkle really does clear com.apple.quarantine on what it
# installs (2.9.6, in Installer.xpc) — a user who ran the command once never has
# to run it again across updates. So this is phrased as a fallback ("if macOS
# refuses"), not an instruction, and sits in one line at the bottom. It cannot be
# dropped: nothing here is notarized, a hand-downloaded DMG still arrives
# quarantined, and release_contract_check.sh asserts this command is present.
read -r -d '' DESCRIPTION <<HTML || true
$CHANGELOG_HTML
<p><small>Not notarized — if macOS refuses to open the app, run <code>xattr -dr com.apple.quarantine "/Applications/$TITLE.app"</code> once; updates $TITLE installs itself clear the flag. <a href="$NOTES_URL">Full release notes</a> · <a href="$NOTES_URL">完整发布说明</a></small></p>
HTML

URL="$(python3 - "$REPO_SLUG" "$TAG_PREFIX$VERSION" "$DMG_NAME" <<'PYURL'
import sys
from urllib.parse import quote
repo, tag, filename = sys.argv[1:]
print(f"https://github.com/{repo}/releases/download/{quote(tag, safe='')}/{quote(filename, safe='')}")
PYURL
)"
XML_URL="$(python3 - "$URL" <<'PYXML'
import sys
from xml.sax.saxutils import quoteattr
print(quoteattr(sys.argv[1]))
PYXML
)"
PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
# Read the real deployment target rather than hardcoding one that can drift.
MIN_OS="$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$ROOT/LiveWallpaper.xcodeproj/project.pbxproj" \
  | sed 's/.*= *//; s/;.*//')"
if [[ -z "$MIN_OS" ]]; then
  echo "ERROR: could not read MACOSX_DEPLOYMENT_TARGET from the project" >&2
  exit 1
fi

CHANNEL_TAG=""
[[ "$CHANNEL" == "beta" ]] && CHANNEL_TAG=$'\n      <sparkle:channel>beta</sparkle:channel>'
NEW_ITEM="$(cat <<XML
    <item>
      <title>Version $VERSION</title>$CHANNEL_TAG
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:descriptionFormat="html"><![CDATA[
$DESCRIPTION
      ]]></description>
      <enclosure url=$XML_URL type="application/octet-stream" $SIG_ATTRS />
    </item>
XML
)"

if [[ "$CHANNEL" == "stable" ]]; then
  STABLE_ITEM="$NEW_ITEM"
  BETA_ITEM=""
  if [[ -n "$OLD_BETA" ]] && version_gt "$OLD_BETA" "$BUILD"; then
    BETA_ITEM="$OLD_BETA_ITEM"
  fi
else
  STABLE_ITEM="$OLD_STABLE_ITEM"
  BETA_ITEM="$NEW_ITEM"
fi

APPCAST_TMP="$(mktemp "$ROOT/.$(basename "$APPCAST").XXXXXX")"
{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/generate-appcast.sh — do not hand-edit. -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$TITLE</title>
    <link>https://raw.githubusercontent.com/$REPO_SLUG/main/$(basename "$APPCAST")</link>
    <description>Updates for $TITLE</description>
    <language>en</language>
XML
  if [[ -n "$STABLE_ITEM" ]]; then printf '%s\n' "$STABLE_ITEM"; fi
  if [[ -n "$BETA_ITEM" ]]; then printf '%s\n' "$BETA_ITEM"; fi
  printf '  </channel>\n</rss>\n'
} > "$APPCAST_TMP"

written="$(item_version "$(appcast_items "$CHANNEL" "$APPCAST_TMP")")"
if [[ "$written" != "$BUILD" ]]; then
  echo "ERROR: wrote sparkle:version=$written, expected $BUILD" >&2
  exit 1
fi
if ! grep -q 'xattr -dr com.apple.quarantine' "$APPCAST_TMP"; then
  echo "ERROR: $APPCAST carries no quarantine instructions; the update dialog would omit them." >&2
  exit 1
fi
if ! xmllint --noout "$APPCAST_TMP" 2>/dev/null; then
  echo "ERROR: $APPCAST is not well-formed XML." >&2
  exit 1
fi
chmod 644 "$APPCAST_TMP"
mv -f "$APPCAST_TMP" "$APPCAST"
APPCAST_TMP=""

echo "  ✓ wrote $APPCAST"
echo "    enclosure: $URL"
echo
echo "  Commit it, create the GitHub release so the enclosure URL exists,"
echo "  then push to main — the app reads the feed from raw.githubusercontent.com."
