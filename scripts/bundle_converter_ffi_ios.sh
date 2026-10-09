#!/usr/bin/env bash
set -euo pipefail

# Xcode build phase: every iOS bundle must contain its own compatible Rust dylib.
case "${PLATFORM_NAME:-}" in
  iphoneos)
    rust_target=aarch64-apple-ios
    expected_arch=arm64
    expected_platform=2
    rust_profile=release
    ;;
  iphonesimulator)
    case "${ARCHS:-}" in
      x86_64) rust_target=x86_64-apple-ios ;;
      arm64) rust_target=aarch64-apple-ios-sim ;;
      *) echo "error: Simulator Rust bundling requires one explicit architecture" >&2; exit 2 ;;
    esac
    expected_arch="$ARCHS"
    expected_platform=7
    rust_profile=release
    if [[ "${CONFIGURATION:-}" == Debug ]]; then
      rust_profile="${CONVERTER_FFI_SIMULATOR_PROFILE:-debug}"
      case "$rust_profile" in
        debug|release) ;;
        *) echo "error: Simulator Rust profile must be debug or release" >&2; exit 2 ;;
      esac
    fi
    ;;
  *) exit 0 ;;
esac
root="$(cd "${SRCROOT:?}/../.." && pwd)"
artifact="$root/target/$rust_target/$rust_profile/libconverter_ffi.dylib"
CONVERTER_FFI_IOS_ARTIFACT="$artifact" CONVERTER_FFI_IOS_ARCH="$expected_arch" \
  CONVERTER_FFI_IOS_PLATFORM="$expected_platform" bash "$root/scripts/verify_converter_ffi_ios.sh"
destination="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
mkdir -p "$destination"
cp "$artifact" "$destination/libconverter_ffi.dylib"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "$PLATFORM_NAME" == iphonesimulator ]]; then
  identity="${identity:--}"
fi
[[ -n "$identity" ]] || { echo "error: missing iOS dylib signing identity" >&2; exit 2; }
codesign --force --sign "$identity" "$destination/libconverter_ffi.dylib"
codesign --verify --strict "$destination/libconverter_ffi.dylib"
