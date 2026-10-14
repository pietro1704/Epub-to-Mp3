#!/usr/bin/env bash
set -euo pipefail

sdk="${EPUB2MP3_APPLE_SDK:?Set EPUB2MP3_APPLE_SDK to iphoneos or iphonesimulator}"
target="${EPUB2MP3_APPLE_CLANG_TARGET:?Set EPUB2MP3_APPLE_CLANG_TARGET}"
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
exec "$(xcrun --sdk "$sdk" --find clang)" \
  -target "$target" \
  -isysroot "$sdk_path" \
  "$@"
