#!/usr/bin/env bash
# PostToolUse hook: when an Edit/Write/MultiEdit lands on a Swift file
# under the SwiftUI view/service layer, queue a flutter-mirror agent
# run so the Dart side stays in lockstep.
#
# The hook does NOT block the tool. It just appends the changed file
# to a queue at .claude/mirror-queue.txt; the agent (invoked
# manually or by an upcoming Stop hook) drains the queue. This keeps
# tool calls cheap and avoids forking heavyweight agents on every
# keystroke.
#
# Why a queue instead of in-line invoke: PostToolUse hooks run
# synchronously in the tool's response window. Spawning an agent
# here would stall every Edit by minutes. The Stop hook (or an
# explicit /agents flutter-mirror) processes the queue in bulk.

set -euo pipefail

# Stdin is JSON describing the tool call.
INPUT="$(cat)"
TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || echo "")
[[ "$TOOL_NAME" =~ ^(Edit|Write|MultiEdit)$ ]] || exit 0

# Extract the file_path the tool touched.
FILE_PATH=$(echo "$INPUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ti = d.get("tool_input", {})
print(ti.get("file_path", ti.get("filePath", "")))
' 2>/dev/null || echo "")

# Only mirror Views and Services under the SwiftUI tree.
case "$FILE_PATH" in
  */ios/EpubToMp3/EpubToMp3/Views/*.swift|*/ios/EpubToMp3/EpubToMp3/Services/*.swift|*/ios/EpubToMp3/EpubToMp3/Models/*.swift)
    ;;
  *)
    exit 0
    ;;
esac

# Append to the mirror queue, dedup-ed.
QUEUE="$(dirname "$0")/../mirror-queue.txt"
mkdir -p "$(dirname "$QUEUE")"
{
  [[ -f "$QUEUE" ]] && grep -vFx "$FILE_PATH" "$QUEUE" || true
  echo "$FILE_PATH"
} > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"

# systemMessage feedback for the user.
COUNT=$(wc -l < "$QUEUE" | tr -d ' ')
cat <<EOF
{"systemMessage": "📱 flutter-mirror queue: ${COUNT} Swift file(s) pending sync. Run /agents flutter-mirror to apply."}
EOF
