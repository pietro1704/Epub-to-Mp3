#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
target_dir="${CARGO_TARGET_DIR:-target}"
case "$target_dir" in
  /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
  *) target_dir="$PROJECT_ROOT/$target_dir" ;;
esac
BACKEND_BIN="$target_dir/debug/converter-server"
if [[ -x "$BACKEND_BIN.exe" ]]; then
  BACKEND_BIN="$BACKEND_BIN.exe"
fi

mise exec -- ruby "$PROJECT_ROOT/scripts/native_build_command.rb" -- mise exec -- cargo build -p converter-server

set --
if [[ "${BACKEND_RELOAD:-0}" == "1" ]]; then
  set -- --reload
fi

exec env \
  HOST="${BACKEND_HOST:-127.0.0.1}" \
  PORT="${BACKEND_PORT:-8000}" \
  "$BACKEND_BIN" "$@"
