#!/bin/bash
# PostToolUse hook: when a Swift file under the iOS target is edited, run
# `swift test` async. Debounced 60s so consecutive edits don't queue
# multiple test runs.

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)

case "$FILE" in
    */ios/EpubToMp3/EpubToMp3/*.swift|*/ios/EpubToMp3/EpubToMp3Tests/*.swift) ;;
    *) exit 0 ;;
esac

STAMP="/tmp/claude-swift-test.stamp"
NOW=$(date +%s)
if [[ -f "$STAMP" ]]; then
    LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( NOW - LAST < 60 )); then exit 0; fi
fi
echo "$NOW" > "$STAMP"

LOG="/tmp/claude-swift-test.log"
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3 || exit 0
{
    echo "=== $(date) :: edited $FILE"
    swift test 2>&1 | tail -5
} >> "$LOG"
