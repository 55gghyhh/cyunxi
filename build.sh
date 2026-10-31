#!/usr/bin/env bash
# 用 Xcode 自带 iOS SDK 编译 KXUniversal.dylib（不需要 Theos）
set -euo pipefail

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ARCH="arm64"
MIN="14.0"
OUT="build"
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
  -arch "$ARCH" \
  -mios-version-min="$MIN" \
  -isysroot "$SDK" \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -Wall \
  -framework UIKit \
  -framework Foundation \
  -framework CoreLocation \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -install_name "@executable_path/Frameworks/KXUniversal.dylib" \
  -o "$OUT/KXUniversal.dylib" \
  src/KXLog.m src/KXUniversal.m

echo "---- 产物 ----"
ls -l "$OUT/KXUniversal.dylib"
file "$OUT/KXUniversal.dylib"
shasum -a 256 "$OUT/KXUniversal.dylib"
