#!/bin/bash
# PostToolUse hook: when a TS/TSX file under web/src is edited, run
# `tsc --noEmit` async. Debounced 30s so consecutive edits don't queue
# multiple typechecks.

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)

case "$FILE" in
    */web/src/*.ts|*/web/src/*.tsx) ;;
    *) exit 0 ;;
esac

STAMP="/tmp/claude-web-typecheck.stamp"
NOW=$(date +%s)
if [[ -f "$STAMP" ]]; then
    LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( NOW - LAST < 30 )); then exit 0; fi
fi
echo "$NOW" > "$STAMP"

LOG="/tmp/claude-web-typecheck.log"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR/web" || exit 0
{
    echo "=== $(date) :: edited $FILE"
    npx tsc --noEmit -p tsconfig.build.json 2>&1 | tail -20
} >> "$LOG"
