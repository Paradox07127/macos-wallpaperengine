#!/bin/bash
# Builds the current helper and embeds the pinned Pro toolchain before Xcode seals the app.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENTS="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
NOTICES="$CONTENTS/Resources/WPEShaderCompilerNotices"
NOTICE_FILES=(DXC-LICENSE.TXT DirectX-Headers-LICENSE MSC-LICENSE.txt MSC-Acknowledgements.rtf)

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
SIGN_OPTIONS=(--force --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}")
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ]; then
    SIGN_OPTIONS+=(--options runtime)
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$NOTICES"

# Re-copy and sign on every invocation: source hashes, entitlements and signing settings can change independently.
embed() {
    local source=$1 destination=$2
    shift 2
    local staged="$destination.embedding"
    cp -f "$source" "$staged"
    chmod u+w "$staged"
    if [ "$(basename "$destination")" = libdxcompiler.dylib ]; then
        # libdxcompiler loads @rpath/libmetalirconverter.dylib; its build rpaths point outside the bundle.
        install_name_tool -delete_rpath /usr/local/lib -delete_rpath @executable_path/../lib \
            -add_rpath @loader_path "$staged"
    fi
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
