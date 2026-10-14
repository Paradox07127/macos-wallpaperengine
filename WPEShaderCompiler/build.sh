#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${1:-$SOURCE_DIR/build}"
if [ -z "${WPE_SHADER_TOOLCHAIN_ROOT:-}" ]; then
  echo 'error: WPE_SHADER_TOOLCHAIN_ROOT must name the staged, pinned shader toolchain inputs' >&2
  exit 1
fi
TOOLCHAIN_ROOT="$(cd "$WPE_SHADER_TOOLCHAIN_ROOT" && pwd -P)"
# The manifest pins headers, both libraries and all four notices before any output is built.
(
  cd "$TOOLCHAIN_ROOT"
  /usr/bin/shasum -a 256 -c "$SOURCE_DIR/toolchain-inputs.sha256"
)
mkdir -p "$BUILD_DIR"
/usr/bin/xcrun --sdk macosx clang++ --version
/usr/bin/xcrun --sdk macosx --show-sdk-version
/usr/bin/xcrun --sdk macosx clang++ -std=c++17 -O2 -Wall -Wextra -Werror -arch arm64 \
  -mmacosx-version-min=14.6 \
  -I "$TOOLCHAIN_ROOT/include/dxc" \
  -I "$TOOLCHAIN_ROOT/include/directx" \
  -I "$TOOLCHAIN_ROOT/include/wsl/stubs" \
  -I "$TOOLCHAIN_ROOT/include" \
  "$SOURCE_DIR/main.cpp" -o "$BUILD_DIR/wpe-shaderc"
printf 'Built %s/wpe-shaderc (-std=c++17 -O2 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=14.6)\n' "$BUILD_DIR"
/usr/bin/shasum -a 256 "$SOURCE_DIR/main.cpp" "$SOURCE_DIR/toolchain-inputs.sha256" "$BUILD_DIR/wpe-shaderc"
