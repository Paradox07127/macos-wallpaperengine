#!/bin/bash
# Builds the current helper and embeds the pinned Pro toolchain before Xcode seals the app.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENTS="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
NOTICES="$CONTENTS/Resources/WPEShaderCompilerNotices"
NOTICE_FILES=(DXC-LICENSE.TXT DXC-ThirdPartyNotices.txt DirectX-Headers-LICENSE MSC-LICENSE.txt MSC-Acknowledgements.rtf MSC-EULA.rtf)

# The vendored FreeType/HarfBuzz/msdfgen code is linked even without the shader toolchain.
# Each line is "<repo path> <bundled name>"; scripts/check_third_party_notices.py reads them.
REPO_ROOT="$(cd "$SOURCE_DIR/.." && pwd)"
THIRD_PARTY_NOTICES="$CONTENTS/Resources/ThirdPartyNotices"
mkdir -p "$THIRD_PARTY_NOTICES"
while read -r source name; do
    cp -f "$REPO_ROOT/$source" "$THIRD_PARTY_NOTICES/$name"
done <<'EOF'
Packages/LiveWallpaperProWPE/Sources/CFreeType/LICENSE.TXT FreeType-LICENSE.TXT
Packages/LiveWallpaperProWPE/Sources/CFreeType/docs/FTL.TXT FreeType-FTL.TXT
Packages/LiveWallpaperProWPE/Sources/CFreeType/src/bdf/README FreeType-BDF-README
Packages/LiveWallpaperProWPE/Sources/CFreeType/src/pcf/README FreeType-PCF-README
Packages/LiveWallpaperProWPE/Sources/CHarfBuzz/COPYING HarfBuzz-COPYING
ThirdPartyNotices/HarfBuzz-ms-use-COPYING HarfBuzz-ms-use-COPYING
Packages/LiveWallpaperProWPE/Sources/CWPESDF/vendor/msdfgen/LICENSE.txt msdfgen-LICENSE.txt
ThirdPartyNotices/README.txt README.txt
EOF

# Xcode does not pass the shell environment; fall back to the inputs staged in this checkout.
if [ -z "${WPE_SHADER_TOOLCHAIN_ROOT:-}" ] && [ -d "$REPO_ROOT/build/wpe-shader-toolchain-inputs" ]; then
    WPE_SHADER_TOOLCHAIN_ROOT="$REPO_ROOT/build/wpe-shader-toolchain-inputs"
fi
if [ -z "${WPE_SHADER_TOOLCHAIN_ROOT:-}" ]; then
    if [ "${CONFIGURATION:-}" != Debug ]; then
        echo 'error: Release requires WPE_SHADER_TOOLCHAIN_ROOT with the pinned shader toolchain inputs' >&2
        exit 1
    fi
    # A Debug build without staged inputs must not accidentally reuse an older embedded toolchain.
    rm -f "$CONTENTS/MacOS/wpe-shaderc" "$CONTENTS/Frameworks/libdxcompiler.dylib" \
        "$CONTENTS/Frameworks/libmetalirconverter.dylib"
    for notice in "${NOTICE_FILES[@]}"; do rm -f "$NOTICES/$notice"; done
    rmdir "$NOTICES" 2>/dev/null || true
    echo 'warning: WPE_SHADER_TOOLCHAIN_ROOT is unset; the Debug parity toolchain is not embedded'
    exit 0
fi

if [ "${CONFIGURATION:-}" == Release ] && [ "${ENABLE_HARDENED_RUNTIME:-NO}" != YES ]; then
    echo 'error: Release shader toolchain embedding requires ENABLE_HARDENED_RUNTIME=YES' >&2
    exit 1
fi

TOOLCHAIN_ROOT="$(cd "$WPE_SHADER_TOOLCHAIN_ROOT" && pwd -P)"
BUILD_DIR="${DERIVED_FILE_DIR:?}/WPEShaderCompiler"
WPE_SHADER_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT" /bin/bash "$SOURCE_DIR/build.sh" "$BUILD_DIR"
HELPER="$BUILD_DIR/wpe-shaderc"
DXCOMPILER="$TOOLCHAIN_ROOT/lib/libdxcompiler.dylib"
METAL_IR_CONVERTER="$TOOLCHAIN_ROOT/lib/libmetalirconverter.dylib"
for source in "$HELPER" "$DXCOMPILER" "$METAL_IR_CONVERTER"; do
    /usr/bin/lipo -verify_arch arm64 "$source"
done
# release-app.sh passes --timestamp here; notarization rejects code without a secure timestamp.
TIMESTAMP_OPTION=--timestamp=none
case " ${OTHER_CODE_SIGN_FLAGS:-} " in *" --timestamp "*) TIMESTAMP_OPTION=--timestamp ;; esac
SIGN_OPTIONS=(--force "$TIMESTAMP_OPTION" --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}")
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ]; then
    SIGN_OPTIONS+=(--options runtime)
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$NOTICES"

# Re-copy and sign on every invocation: source hashes, entitlements and signing settings can change independently.
embed() {
    local source=$1 destination=$2
    shift 2
    local staged="$destination.embedding"
    # Preserve the original universal MSC library; EA1844 separately restricts modifications.
    # The arm64 helper loads only its arm64 slice. Other inputs may retain the existing thinning policy.
    if [ "$source" = "$METAL_IR_CONVERTER" ] || [ "$(/usr/bin/lipo -archs "$source")" = arm64 ]; then
        cp -f "$source" "$staged"
    else
        /usr/bin/lipo "$source" -thin arm64 -output "$staged"
    fi
    chmod u+w "$staged"
    # Re-sign for library validation; do not strip, patch install names or thin MSC.
    codesign "${SIGN_OPTIONS[@]}" --identifier "$(basename "$destination")" "$@" "$staged"
    codesign --verify --strict "$staged"
    mv -f "$staged" "$destination"
}

embed "$METAL_IR_CONVERTER" "$CONTENTS/Frameworks/libmetalirconverter.dylib"
embed "$DXCOMPILER" "$CONTENTS/Frameworks/libdxcompiler.dylib"
embed "$HELPER" "$CONTENTS/MacOS/wpe-shaderc" --entitlements "$SOURCE_DIR/wpe-shaderc.entitlements"
for notice in "${NOTICE_FILES[@]}"; do
    cp -f "$TOOLCHAIN_ROOT/licenses/$notice" "$NOTICES/$notice"
done
printf 'Embedded Pro shader toolchain (signing identity %s)\n' "${EXPANDED_CODE_SIGN_IDENTITY:--}"
/usr/bin/shasum -a 256 "$CONTENTS/MacOS/wpe-shaderc" "$CONTENTS/Frameworks/libdxcompiler.dylib" \
    "$CONTENTS/Frameworks/libmetalirconverter.dylib"
