#!/usr/bin/env bash
# PostToolUse notification only; task-authorized checks are explicit.
# A hook must not resolve/install packages or share debounce state across checkouts.
set -euo pipefail
PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null || true)
case "$FILE" in
    */web/src/*.ts|*/web/src/*.tsx) ;;
    *) exit 0 ;;
esac
printf '%s\n' 'web_typecheck_after_edit: review the affected web source under the current task acceptance; automatic typechecks and package installation are disabled.' >&2
