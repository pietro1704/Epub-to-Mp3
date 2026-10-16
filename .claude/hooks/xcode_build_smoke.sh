#!/bin/bash
# Stop notification only. Never start native work after the session becomes idle.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
CHANGED=$(git -C "$ROOT" diff --name-only HEAD -- ios/EpubToMp3 2>/dev/null || true)
UNTRACKED=$(git -C "$ROOT" ls-files --others --exclude-standard -- ios/EpubToMp3 2>/dev/null || true)
if ! printf '%s\n%s\n' "$CHANGED" "$UNTRACKED" | grep -qE '^ios/EpubToMp3/.*\.swift$'; then
    exit 0
fi
printf '%s\n' 'xcode_build_smoke: native verification pending; automatic compilation disabled. Use an explicit guarded task after reviewing docs/agent-workflow.md.' >&2
