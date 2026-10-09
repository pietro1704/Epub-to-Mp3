#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  x86_64) target=x86_64-apple-ios; arch=x86_64 ;;
  arm64) target=aarch64-apple-ios-sim; arch=arm64 ;;
  *) exit 2 ;;
esac
verify="$root/scripts/verify_converter_ffi_ios.sh"
profile="${CONVERTER_FFI_SIMULATOR_PROFILE:-debug}"
case "$profile" in debug|release) ;; *) exit 2 ;; esac
simulator="$root/target/$target/$profile/libconverter_ffi.dylib"
device="$root/target/aarch64-apple-ios/release/libconverter_ffi.dylib"
mac="$root/target/release/libconverter_ffi.dylib"
expect_rejection() {
  if env CONVERTER_FFI_IOS_ARTIFACT="$1" CONVERTER_FFI_IOS_ARCH="$2" \
      CONVERTER_FFI_IOS_PLATFORM="$3" bash "$verify"; then
    echo "FAIL: verifier accepted $1 for $2/$3" >&2; exit 1
  fi
}
[[ -f "$simulator" && -f "$device" && -f "$mac" ]] || {
  echo "Packaging regression requires real existing Simulator/device/macOS artifacts" >&2; exit 2;
}
expect_rejection "$device" "$arch" 7
expect_rejection "$mac" "$arch" 7
expect_rejection "$simulator" arm64 2
expect_rejection "$simulator" "$arch" 99
bundle_root="$(mktemp -d /tmp/epub-simulator-bundle.XXXXXX)"
xcrun clang -target "$arch-apple-ios15.0-simulator" -dynamiclib \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  "$root/scripts/fixtures/incomplete_converter_ffi.c" -o "$bundle_root/incomplete.dylib"
expect_rejection "$bundle_root/incomplete.dylib" "$arch" 7
CONVERTER_FFI_IOS_ARTIFACT="$device" bash "$verify"
CONVERTER_FFI_IOS_ARTIFACT="$simulator" CONVERTER_FFI_IOS_ARCH="$arch" \
  CONVERTER_FFI_IOS_PLATFORM=7 bash "$verify"
SRCROOT="$root/ios/EpubToMp3" PLATFORM_NAME=iphonesimulator ARCHS="$arch" \
  CONFIGURATION=Debug TARGET_BUILD_DIR="$bundle_root" FRAMEWORKS_FOLDER_PATH=Frameworks \
  EXPANDED_CODE_SIGN_IDENTITY=- bash "$root/scripts/bundle_converter_ffi_ios.sh"
CONVERTER_FFI_IOS_ARTIFACT="$bundle_root/Frameworks/libconverter_ffi.dylib" \
  CONVERTER_FFI_IOS_ARCH="$arch" CONVERTER_FFI_IOS_PLATFORM=7 bash "$verify"
echo "PASS: wrong-platform rejection, real artifact checks and signed Simulator bundling"
echo "Isolated signed fixture retained at $bundle_root"
