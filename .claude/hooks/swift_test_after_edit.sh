#!/bin/bash
# PostToolUse hook: when a Swift file under the iOS target is edited, run
# `swift test` async through the native safety lease. Debounced per checkout.

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)

case "$FILE" in
    */ios/EpubToMp3/EpubToMp3/*.swift|*/ios/EpubToMp3/EpubToMp3Tests/*.swift) ;;
    *) exit 0 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
GUARD="$ROOT/scripts/native_job.rb"
if [[ ! -f "$GUARD" || ! -f "$ROOT/scripts/native_build_preflight.rb" ]]; then
    echo "swift_test_after_edit: native safety guard unavailable; compilation skipped." >&2
    exit 0
fi
mkdir -p "$ROOT/.reports/hooks"
STAMP="$ROOT/.reports/hooks/swift-test.stamp"
NOW=$(date +%s)
if [[ -f "$STAMP" ]]; then
    LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( NOW - LAST < 60 )); then exit 0; fi
fi
echo "$NOW" > "$STAMP"

LOG="$ROOT/.reports/hooks/swift-test.log"
cd "$ROOT/ios/EpubToMp3" || exit 0
echo "=== $(date) :: edited $FILE" >> "$LOG"
NATIVE_PID=""
cancel_native() {
    trap - INT TERM HUP
    if [[ -n "$NATIVE_PID" ]]; then
        kill -"$1" "$NATIVE_PID" 2>/dev/null || true
        wait "$NATIVE_PID" || true
    fi
    exit "$2"
}
trap 'cancel_native INT 130' INT
trap 'cancel_native TERM 143' TERM
trap 'cancel_native HUP 129' HUP
mise exec -- ruby "$GUARD" build -- mise exec -- swift test --jobs 1 >> "$LOG" 2>&1 &
NATIVE_PID=$!
if wait "$NATIVE_PID"; then STATUS=0; else STATUS=$?; fi
NATIVE_PID=""
trap - INT TERM HUP
exit "$STATUS"
