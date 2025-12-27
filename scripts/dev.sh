#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  if [[ -n "${BACK_PID:-}" ]]; then
    kill "$BACK_PID" 2>/dev/null || true
  fi
  if [[ -n "${FRONT_PID:-}" ]]; then
    kill "$FRONT_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

BACKEND_PORT="${BACKEND_PORT:-8000}"
python -m uvicorn python_app.server:app --reload --port "$BACKEND_PORT" &
BACK_PID=$!

cd web
npm install >/dev/null 2>&1 || true
VITE_API_BASE="${VITE_API_BASE:-http://127.0.0.1:${BACKEND_PORT}}" npm run dev -- --host &
FRONT_PID=$!

wait "$BACK_PID" "$FRONT_PID"
