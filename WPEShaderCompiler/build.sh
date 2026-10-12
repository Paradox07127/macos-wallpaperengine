#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${1:-$SOURCE_DIR/build}"
DXC_DIR="/Users/example/Developer/DirectXShaderCompiler"
mkdir -p "$BUILD_DIR"
clang++ -std=c++17 -O2 -Wall -Wextra -Werror -arch arm64 \
  -mmacosx-version-min=14.6 \
  -I "$DXC_DIR/include/dxc" \
  -I "$DXC_DIR/external/DirectX-Headers/include/directx" \
  -I "$DXC_DIR/external/DirectX-Headers/include/wsl/stubs" \
  -I /usr/local/include \
  "$SOURCE_DIR/main.cpp" -o "$BUILD_DIR/wpe-shaderc"
printf 'Built %s/wpe-shaderc (arm64, minimum macOS 14.6)\n' "$BUILD_DIR"
