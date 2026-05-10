#!/bin/bash
# PostToolUse hook: when a TS/TSX file under web/src is edited, run
# `tsc --noEmit` async. The web app's `npm run build` does typecheck
# but `npx vitest run` doesn't — so a type error sneaks past the test
# suite and lands on CI. Catch it locally before commit.

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)

case "$FILE" in
    */web/src/*.ts|*/web/src/*.tsx) ;;
    *) exit 0 ;;
esac

LOG="/tmp/claude-web-typecheck.log"
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/web || exit 0
{
    echo "=== $(date) :: edited $FILE"
    npx tsc --noEmit -p tsconfig.build.json 2>&1 | tail -20
} >> "$LOG"
