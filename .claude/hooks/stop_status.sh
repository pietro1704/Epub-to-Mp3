#!/usr/bin/env bash
# Optional legacy observation only; embedded Rust owns current conversion.
# Reads bounded compatibility records only with explicit EPUB_LEGACY_CONTEXT=1.
set -euo pipefail
if [[ "${EPUB_LEGACY_CONTEXT:-0}" != "1" ]]; then
    cat >/dev/null
    exit 0
fi
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec python3 "$PROJECT_DIR/.claude/hooks/legacy_conversion_context.py" stop "$PROJECT_DIR"
