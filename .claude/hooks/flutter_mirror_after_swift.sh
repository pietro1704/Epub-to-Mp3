#!/usr/bin/env bash
# Compatibility notice for an explicitly named parity task only.
# No automatic queue, agent dispatch or platform execution is performed.
set -euo pipefail
PAYLOAD=$(cat)
[[ "${EPUB_FLUTTER_PARITY:-0}" == "1" ]] || exit 0
[[ -n "${EPUB_FLUTTER_PARITY_TASK:-}" ]] || exit 0
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)
case "$FILE" in
    */ios/EpubToMp3/EpubToMp3/*.swift) ;;
    *) exit 0 ;;
esac
printf '%s\n' 'flutter_mirror_after_swift: Swift source changed during the explicitly selected parity task. Review its named behavior through the canonical specialist; no queue or delegate was started.' >&2
