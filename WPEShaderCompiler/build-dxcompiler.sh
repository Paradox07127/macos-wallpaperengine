#!/usr/bin/env bash
# Builds the pinned DXC without SPIR-V as an arm64 MinSizeRel libdxcompiler.dylib and stages it stripped.
# Usage: build-dxcompiler.sh <work-dir> <toolchain-root>
# <work-dir> keeps the clone, the build tree and the unstripped library for symbolication.
# Re-running resumes: an existing clone and configured build tree are reused.
set -euo pipefail

DXC_URL=https://github.com/microsoft/DirectXShaderCompiler
DXC_COMMIT=01b62ad47db7dee3dd33f90e7339cf9e860b3f93
HEADERS_COMMIT=980971e835876dc0cde415e8f9bc646e64667bf7
# MSC's ShaderID depends on this string; a depth-1 detached clean checkout produces it.
EXPECTED_VERSION='dxc(private) 1.9.0.1 (01b62ad4)'

WORK_DIR="${1:?usage: build-dxcompiler.sh <work-dir> <toolchain-root>}"
TOOLCHAIN_ROOT="${2:?usage: build-dxcompiler.sh <work-dir> <toolchain-root>}"
SRC="$WORK_DIR/src"
BUILD="$WORK_DIR/build"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$SRC"
    (
        cd "$SRC"
        git init -q
        git remote add origin "$DXC_URL"
        git fetch -q --depth 1 origin "$DXC_COMMIT"
        git checkout -q --detach FETCH_HEAD
        git submodule update -q --init --depth 1 external/DirectX-Headers
        # Non-Windows hosts force SPIR-V codegen on; -DENABLE_SPIRV_CODEGEN=OFF alone has no effect.
        sed -i '' '134s/^if(NOT WIN32)$/if(FALSE)/' CMakeLists.txt
        # Hides the edit from the version generator so the version carries no -dirty suffix.
        git update-index --assume-unchanged CMakeLists.txt
    )
fi
[ "$(cd "$SRC" && git rev-parse HEAD)" = "$DXC_COMMIT" ]
[ "$(cd "$SRC/external/DirectX-Headers" && git rev-parse HEAD)" = "$HEADERS_COMMIT" ]
[ "$(sed -n 134p "$SRC/CMakeLists.txt")" = 'if(FALSE)' ]

if [ ! -f "$BUILD/build.ninja" ]; then
    cmake -S "$SRC" -B "$BUILD" -G Ninja -C "$SRC/cmake/caches/PredefinedParams.cmake" \
        -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6 \
        -DLLVM_ENABLE_ASSERTIONS=OFF -DHLSL_INCLUDE_TESTS=OFF -DSPIRV_BUILD_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DENABLE_SPIRV_CODEGEN=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_MetalIRConverter=ON
fi
ninja -C "$BUILD" dxcompiler

BUILT="$BUILD/lib/libdxcompiler.dylib"
strings "$BUILT" | grep -xF "$EXPECTED_VERSION" >/dev/null || {
    echo "error: $BUILT does not carry the version string '$EXPECTED_VERSION'" >&2
    exit 1
}
cp -f "$BUILT" "$WORK_DIR/libdxcompiler.unstripped.dylib"
STAGED="$TOOLCHAIN_ROOT/lib/libdxcompiler.dylib"
mkdir -p "$TOOLCHAIN_ROOT/lib"
cp -f "$BUILT" "$STAGED"
chmod u+w "$STAGED"
strip -x "$STAGED"
/usr/bin/shasum -a 256 "$WORK_DIR/libdxcompiler.unstripped.dylib" "$STAGED"
