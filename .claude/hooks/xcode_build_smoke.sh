#!/bin/bash
# Stop hook: if any Swift file in the iOS target was edited this turn,
# verify it still compiles for macOS Debug. Blocks on BUILD FAILED so
# the assistant fixes drift before declaring done.
#
# Skipped when:
#   - No .swift edits this turn (we don't peek at git status — we
#     check whether DerivedData mtime changed).
#   - The .build / .xcodeproj is locked by an active xcodebuild
#     (avoid double-builds when the user is already running one).

set -euo pipefail

cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3 || {
    echo '{"systemMessage":"xcode_build_smoke: ios/EpubToMp3 not found, skipping"}'
    exit 0
}

PROJ=EpubToMp3.xcodeproj
[ -d "$PROJ" ] || exit 0

# Skip when the user is mid-build to avoid lock contention.
if pgrep -f "xcodebuild .*EpubToMp3" >/dev/null 2>&1; then
    exit 0
fi

# Only run when at least one Swift file changed in the working tree —
# avoids paying ~30 s on no-op turns.
CHANGED=$(git -C /Users/pietropugliesi/Developer/Epub-to-Mp3 diff --name-only HEAD 2>/dev/null | grep -cE '^ios/EpubToMp3/EpubToMp3.*\.swift$' || true)
STAGED=$(git -C /Users/pietropugliesi/Developer/Epub-to-Mp3 diff --cached --name-only 2>/dev/null | grep -cE '^ios/EpubToMp3/EpubToMp3.*\.swift$' || true)
if [ "$CHANGED" = "0" ] && [ "$STAGED" = "0" ]; then
    exit 0
fi

LOG=$(mktemp -t xcode_smoke.XXXXXX)
if xcodebuild -project "$PROJ" -scheme EpubToMp3 \
        -destination 'platform=macOS' -configuration Debug build \
        > "$LOG" 2>&1; then
    rm -f "$LOG"
    exit 0
fi

# Build failed — emit blocking JSON so the assistant fixes it.
TAIL=$(grep -E "error:" "$LOG" | head -10)
rm -f "$LOG"
cat <<EOF
{"continue":false,"stopReason":"xcodebuild macOS Debug failed:\n$TAIL"}
EOF
