#!/bin/bash
# Stop hook (async): if any Swift file in the iOS target was edited this
# turn, verify it still compiles for macOS Debug. Runs async so it never
# stalls the Stop — on BUILD FAILED it injects the error as
# additionalContext, surfacing on the next turn for the assistant to fix.
#
# Skipped when:
#   - No .swift edits in the working tree (git diff gate below).
#   - The native safety guard is unavailable. Its lease and preflight, rather
#     than a PID snapshot, exclude other native work and active Simulators.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT/ios/EpubToMp3" || {
    echo '{"systemMessage":"xcode_build_smoke: ios/EpubToMp3 not found, skipping"}'
    exit 0
}

PROJ=EpubToMp3.xcodeproj
[ -d "$PROJ" ] || exit 0

GUARD="$ROOT/scripts/native_job.rb"
if [[ ! -f "$GUARD" || ! -f "$ROOT/scripts/native_build_preflight.rb" ]]; then
    echo "xcode_build_smoke: native safety guard unavailable; compilation skipped." >&2
    exit 0
fi

# Only run when at least one Swift file changed in the working tree —
# avoids paying ~30 s on no-op turns.
CHANGED=$(git -C "$ROOT" diff --name-only HEAD 2>/dev/null | grep -cE '^ios/EpubToMp3/EpubToMp3.*\.swift$' || true)
STAGED=$(git -C "$ROOT" diff --cached --name-only 2>/dev/null | grep -cE '^ios/EpubToMp3/EpubToMp3.*\.swift$' || true)
if [ "$CHANGED" = "0" ] && [ "$STAGED" = "0" ]; then
    exit 0
fi

LOG=$(mktemp -t xcode_smoke.XXXXXX)
NATIVE_PID=""
cancel_native() {
    trap - INT TERM HUP
    if [[ -n "$NATIVE_PID" ]]; then
        kill -"$1" "$NATIVE_PID" 2>/dev/null || true
        wait "$NATIVE_PID" || true
    fi
    rm -f "$LOG"
    exit "$2"
}
trap 'cancel_native INT 130' INT
trap 'cancel_native TERM 143' TERM
trap 'cancel_native HUP 129' HUP
mise exec -- ruby "$GUARD" build -- mise exec -- xcodebuild -project "$PROJ" -scheme EpubToMp3 \
        -destination 'platform=macOS' -configuration Debug -jobs 1 build \
        > "$LOG" 2>&1 &
NATIVE_PID=$!
if wait "$NATIVE_PID"; then STATUS=0; else STATUS=$?; fi
NATIVE_PID=""
trap - INT TERM HUP
if [[ "$STATUS" = "0" ]]; then
    rm -f "$LOG"
    exit 0
fi

if [[ "$STATUS" = "75" ]]; then
    cat "$LOG" >&2
    rm -f "$LOG"
    echo '{"systemMessage":"xcode_build_smoke: native safety guard refused compilation; no build result."}'
    exit "$STATUS"
fi

# Build failed — async hooks can't block Stop, so inject the error as
# context. It surfaces on the next turn for the assistant to fix.
TAIL=$(grep -E "error:" "$LOG" | head -10 || true)
rm -f "$LOG"
jq -n --arg tail "$TAIL" \
  '{additionalContext: ("## xcodebuild macOS Debug FAILED\nThe iOS target no longer compiles for macOS. Fix before continuing:\n" + $tail)}'
exit "$STATUS"
