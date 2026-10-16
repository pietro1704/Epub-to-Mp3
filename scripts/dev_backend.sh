#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_BIN="$PROJECT_ROOT/target/debug/converter-server"
if [[ -x "$BACKEND_BIN.exe" ]]; then
  BACKEND_BIN="$BACKEND_BIN.exe"
fi

mise exec -- ruby "$PROJECT_ROOT/scripts/native_build_command.rb" -- mise exec -- cargo build -p converter-server

backend_args=()
if [[ "${BACKEND_RELOAD:-0}" == "1" ]]; then
  backend_args+=(--reload)
fi

exec env \
  HOST="${BACKEND_HOST:-127.0.0.1}" \
  PORT="${BACKEND_PORT:-8000}" \
  "$BACKEND_BIN" "${backend_args[@]}"
