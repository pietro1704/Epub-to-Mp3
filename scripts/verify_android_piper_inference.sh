#!/usr/bin/env bash
set -euo pipefail

mode="${1-full}"
if [[ "$#" -gt 1 ]]; then
  echo 'Expected one fixed Android verification mode.' >&2
  exit 64
fi
case "$mode" in
  full|identity) ;;
  *) echo 'Unknown Android verification mode.' >&2; exit 64 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
api_level="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
abi_list="$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
native_bridge="$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
arm64_isa="$(adb shell getprop ro.dalvik.vm.isa.arm64 | tr -d '\r')"
test "$api_level" = "35"
case ",$abi_list," in *,arm64-v8a,*) ;; *) echo "ARM64 ABI is unavailable: $abi_list" >&2; exit 1 ;; esac
test "$native_bridge" = "libndk_translation.so"
test "$arm64_isa" = "x86_64"
printf 'ANDROID_ARM64_ABI_TRANSLATION: api=%s guest=%s arm64Bridge=%s arm64Isa=%s\n' \
  "$api_level" "$(adb shell getprop ro.product.cpu.abi | tr -d '\r')" "$native_bridge" "$arm64_isa"
mkdir -p .reports/tts-preferences
cd flutter_app
mise exec -- flutter drive --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk --driver=test_driver/integration_test.dart --target=integration_test/android_piper_inference_test.dart -d emulator-5554 2>&1 | tee ../.reports/tts-preferences/android-inference.log
grep -F 'ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none' ../.reports/tts-preferences/android-inference.log
if [[ "$mode" == full ]]; then
  grep -F 'ANDROID_FABER_ABI_TRANSLATION: model=pt_BR-faber-medium' ../.reports/tts-preferences/android-inference.log
fi
