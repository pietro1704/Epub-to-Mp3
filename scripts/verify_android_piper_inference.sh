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

# Runs only after a failed drive, while the runner and a possibly dead emulator still exist.
collect_diagnostics() {
  local state report=../.reports/tts-preferences/android-diagnostics.log
  state="$(adb -s emulator-5554 get-state 2>&1 | tr -d '\r' | tail -n 1)" || true
  {
    echo "ANDROID_DIAGNOSTICS: adbState=$state"
    adb devices -l || true
    echo '--- emulator processes'
    ps -eo pid,etime,rss,args | grep -E '[q]emu-system|[e]mulator -' || echo 'no emulator process'
    echo '--- host memory and kernel kills'
    if command -v free >/dev/null; then free -m; fi
    if command -v dmesg >/dev/null; then
      sudo -n dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|segfault' | tail -n 20 || true
    fi
    # logcat blocks waiting for a device that is not online.
    if [[ "$state" == device ]]; then
      echo '--- logcat'
      adb -s emulator-5554 logcat -d -b crash,main -t 400 || true
    fi
  } 2>&1 | tee "$report"
}

cd flutter_app
drive_status=0
mise exec -- flutter drive --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk --driver=test_driver/integration_test.dart --target=integration_test/android_piper_inference_test.dart -d emulator-5554 2>&1 | tee ../.reports/tts-preferences/android-inference.log || drive_status=$?
if [[ "$drive_status" -ne 0 ]]; then
  collect_diagnostics || true
  exit "$drive_status"
fi
grep -F 'ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none' ../.reports/tts-preferences/android-inference.log
if [[ "$mode" == full ]]; then
  grep -F 'ANDROID_FABER_ABI_TRANSLATION: model=pt_BR-faber-medium' ../.reports/tts-preferences/android-inference.log
fi
