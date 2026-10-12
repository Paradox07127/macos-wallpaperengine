#!/bin/bash
# Copies wpe-shaderc and the two libraries it dlopens into the Pro app and signs them before Xcode seals the app.
# Missing local builds only warn: the app then reports the parity toolchain as unavailable.
set -euo pipefail

HELPER=/Users/example/Developer/wpe-shaderc-build/wpe-shaderc
DXCOMPILER=/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib
METAL_IR_CONVERTER=/usr/local/lib/libmetalirconverter.dylib

for source in "$HELPER" "$DXCOMPILER" "$METAL_IR_CONVERTER"; do
    if [ ! -f "$source" ]; then
        echo "warning: $source missing; the parity shader toolchain is not embedded"
        exit 0
    fi
done

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
SIGN_OPTIONS=(--force --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}")
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ]; then
    SIGN_OPTIONS+=(--options runtime)
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks"

# Skips a file whose embedded copy is newer than its source; the copy is signed before it takes the final name.
embed() {
    local source=$1 destination=$2
    shift 2
    if [ -f "$destination" ] && [ ! "$source" -nt "$destination" ]; then
        return
    fi
    local staged="$destination.embedding"
    cp -f "$source" "$staged"
    chmod u+w "$staged"
    if [ "$(basename "$destination")" = libdxcompiler.dylib ]; then
        # libdxcompiler loads @rpath/libmetalirconverter.dylib; its build rpaths point outside the bundle.
        install_name_tool -delete_rpath /usr/local/lib -delete_rpath @executable_path/../lib \
            -add_rpath @loader_path "$staged"
    fi
    codesign "${SIGN_OPTIONS[@]}" --identifier "$(basename "$destination")" "$@" "$staged"
    mv -f "$staged" "$destination"
}

embed "$METAL_IR_CONVERTER" "$CONTENTS/Frameworks/libmetalirconverter.dylib"
embed "$DXCOMPILER" "$CONTENTS/Frameworks/libdxcompiler.dylib"
embed "$HELPER" "$CONTENTS/MacOS/wpe-shaderc" --entitlements "$SRCROOT/WPEShaderCompiler/wpe-shaderc.entitlements"
