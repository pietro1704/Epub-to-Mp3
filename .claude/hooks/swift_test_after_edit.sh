#!/bin/bash
# PostToolUse notification only. Native compilation is always an explicit task.
set -euo pipefail
PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)
case "$FILE" in
    */ios/EpubToMp3/EpubToMp3/*.swift|*/ios/EpubToMp3/EpubToMp3Tests/*.swift|*/ios/EpubToMp3/EpubToMp3UITests/*.swift) ;;
    *) exit 0 ;;
esac
printf '%s\n' 'swift_test_after_edit: native verification pending; automatic compilation disabled. Use an explicit guarded task after reviewing docs/agent-workflow.md.' >&2
