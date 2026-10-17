#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:?destination required}"
scheme="${2:?scheme required}"
derived_data="${3:?derived data required}"
action="${4:?action required}"
build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if [[ "$destination" == *macOS* ]]; then
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported macOS host architecture: $host_arch" >&2; exit 2 ;;
  esac
  for artifact in "$root/target/release/libconverter_ffi.dylib" \
    "$root/target/onnxruntime-macos-prebuilt/$host_arch/lib/libonnxruntime.dylib"; do
    actual_arch="$(xcrun lipo -archs "$artifact")"
    if [[ "$actual_arch" != "$host_arch" ]]; then
      echo "Architecture mismatch for $artifact: expected $host_arch, got $actual_arch" >&2
      exit 2
    fi
  done
  build_settings+=("ARCHS=$host_arch" ONLY_ACTIVE_ARCH=YES)
  if [[ "$destination" == 'platform=macOS' ]]; then
    destination="platform=macOS,arch=$host_arch"
  fi
fi
cd "$root/ios/EpubToMp3"
exec xcodebuild \
  -project EpubToMp3.xcodeproj \
  -scheme "$scheme" \
  -destination "$destination" \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  -jobs 1 \
  -parallel-testing-enabled NO \
  "${build_settings[@]}" \
  "$action"
