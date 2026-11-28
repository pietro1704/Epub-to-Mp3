#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
reports=.reports/tts-preferences/android-ocr
mkdir -p "$reports"
device=(adb -s emulator-5554)
# Stream before installing either APK so a crash or a step timeout leaves evidence.
"${device[@]}" logcat -v threadtime -b main -b system -b crash -T 1 > "$reports/logcat.txt" 2>&1 &
logcat_pid=$!
trap 'kill "$logcat_pid" 2>/dev/null || true' EXIT

package=com.pietrocode.epubtomp3.flutter_app
runner="$package.test/androidx.test.runner.AndroidJUnitRunner"
method=recognizesTextDrawnOnAPdfPage
test_class="$package.PdfPageOcrR8Test"
apk=flutter_app/build/app/outputs/apk
{
  timeout 60 "${device[@]}" install -r "$apk/release/app-release.apk"
  timeout 60 "${device[@]}" install -r -t "$apk/androidTest/release/app-release-androidTest.apk"
  timeout 10 "${device[@]}" shell pm list instrumentation
} 2>&1 | tee "$reports/install.txt"

# AndroidJUnitRunner's log-only mode discovers the annotated method without running its body.
instrument() {
  local stage=$1 deadline=$2
  shift 2
  local report="$reports/$stage.txt"
  timeout -k 5 "$deadline" "${device[@]}" shell am instrument -w -r "$@" \
    -e class "$test_class#$method" "$runner" 2>&1 | tr -d '\r' | tee "$report"
  # am instrument can exit zero for an empty suite, a runner error, or an assertion failure.
  grep -Fxq "INSTRUMENTATION_STATUS: class=$test_class" "$report"
  grep -Fxq "INSTRUMENTATION_STATUS: test=$method" "$report"
  grep -Fxq 'OK (1 test)' "$report"
}
instrument discovery 60 -e log true
instrument ocr 180
