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

python -m uvicorn python_app.server:app --reload --port 8000 &
BACK_PID=$!

cd web
npm install >/dev/null 2>&1 || true
npm run dev -- --host &
FRONT_PID=$!

wait "$BACK_PID" "$FRONT_PID"
