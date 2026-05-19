#!/usr/bin/env bash
# PostToolUse hook: when an Edit/Write/MultiEdit lands on a SwiftUI view/service
# layer, queue a flutter-mirror agent run so the Dart side stays in lockstep.
#
# Does NOT block the tool — just appends to .claude/mirror-queue.txt; the
# /agents flutter-mirror agent (or a future Stop hook) drains the queue.

set -euo pipefail

INPUT="$(cat)"
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL_NAME" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)
case "$FILE_PATH" in
  */ios/EpubToMp3/EpubToMp3/Views/*.swift|*/ios/EpubToMp3/EpubToMp3/Services/*.swift|*/ios/EpubToMp3/EpubToMp3/Models/*.swift) ;;
  *) exit 0 ;;
esac

QUEUE="$(dirname "$0")/../mirror-queue.txt"
mkdir -p "$(dirname "$QUEUE")"
{
  [[ -f "$QUEUE" ]] && grep -vFx "$FILE_PATH" "$QUEUE" || true
  echo "$FILE_PATH"
} > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"

COUNT=$(wc -l < "$QUEUE" | tr -d ' ')
cat <<EOF
{"systemMessage": "📱 flutter-mirror queue: ${COUNT} Swift file(s) pending sync. Run /agents flutter-mirror to apply."}
EOF
