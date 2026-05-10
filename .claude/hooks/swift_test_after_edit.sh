#!/bin/bash
# PostToolUse hook: when a Swift file under ios/EpubToMp3/EpubToMp3 is
# edited, run the SPM test suite. Async + non-blocking — Claude keeps
# working; the result is logged so we notice regressions early.
#
# Reads the edited file path from stdin JSON and exits 0 if the path
# is outside the iOS app (no-op).

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)

# Only act on Swift sources under the iOS target.
case "$FILE" in
    */ios/EpubToMp3/EpubToMp3/*.swift|*/ios/EpubToMp3/EpubToMp3Tests/*.swift) ;;
    *) exit 0 ;;
esac

LOG="/tmp/claude-swift-test.log"
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3 || exit 0
{
    echo "=== $(date) :: edited $FILE"
    swift test 2>&1 | tail -5
} >> "$LOG"
