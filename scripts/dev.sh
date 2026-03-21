#!/usr/bin/env bash
set -euo pipefail

BACKEND_PORT="${BACKEND_PORT:-8000}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_RELOAD="${BACKEND_RELOAD:-0}"
FRONTEND_HOST="${FRONTEND_HOST:-127.0.0.1}"
FRONTEND_DIR="web"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACK_PID=""
FRONT_PID=""
SHUTTING_DOWN=0

child_pids() {
  local parent_pid="$1"
  ps -o pid= --ppid "$parent_pid" 2>/dev/null | tr -d ' '
}

terminate_tree() {
  local root_pid="$1"
  local signal_name="${2:-TERM}"
  [[ -n "$root_pid" ]] || return 0
  kill -0 "$root_pid" 2>/dev/null || return 0

  local child_pid=""
  while read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    terminate_tree "$child_pid" "$signal_name"
  done < <(child_pids "$root_pid")

  kill "-${signal_name}" "$root_pid" 2>/dev/null || true
}

wait_for_exit() {
  local pid="$1"
  local attempts="${2:-40}"
  local delay="${3:-0.25}"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    ((i += 1))
    if (( i >= attempts )); then
      return 1
    fi
    sleep "$delay"
  done
  return 0
}

stop_process() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  terminate_tree "$pid" TERM
  if ! wait_for_exit "$pid" 20 0.25; then
    terminate_tree "$pid" KILL
    wait_for_exit "$pid" 8 0.25 || true
  fi
}

command_for_pid() {
  local pid="$1"
  ps -o command= -p "$pid" 2>/dev/null
}

matches_command_pattern() {
  local pid="$1"
  local pattern="$2"
  local cmd
  cmd="$(command_for_pid "$pid")"
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" =~ $pattern ]]
}

is_project_process() {
  local pid="$1"
  local pattern="$2"
  local cmd
  cmd="$(command_for_pid "$pid")"
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" == *"$PROJECT_ROOT"* ]] || return 1
  [[ "$cmd" =~ $pattern ]]
}

cleanup_matching_processes() {
  local pattern="$1"
  local pid=""
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if is_project_process "$pid" "$pattern"; then
      echo "[dev] stopping stale process $pid: $(command_for_pid "$pid")"
      stop_process "$pid"
    fi
  done < <(ps -axo pid=)
}

cleanup_port_listeners() {
  local port="$1"
  local pattern="$2"
  local pid=""
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if matches_command_pattern "$pid" "$pattern"; then
      echo "[dev] stopping stale listener $pid on :$port: $(command_for_pid "$pid")"
      stop_process "$pid"
    fi
  done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)
}

cleanup_stale_dev_processes() {
  cleanup_port_listeners "$BACKEND_PORT" 'python .*uvicorn .*python_app\.server:app'
  cleanup_matching_processes 'python .*uvicorn .*python_app\.server:app'
  cleanup_matching_processes 'node .*/vite([^[:alnum:]_]|$)'
  cleanup_matching_processes 'npm run dev -- --host|npm run dev --host'
}

start_backend() {
  local -a backend_cmd=(python -m uvicorn python_app.server:app --host "$BACKEND_HOST" --port "$BACKEND_PORT")
  if [[ "$BACKEND_RELOAD" == "1" || "$BACKEND_RELOAD" == "true" || "$BACKEND_RELOAD" == "yes" ]]; then
    backend_cmd+=(--reload)
  fi
  echo "[dev] starting backend: ${backend_cmd[*]}"
  "${backend_cmd[@]}" &
  BACK_PID=$!
}

start_frontend() {
  echo "[dev] starting frontend on ${FRONTEND_HOST}"
  (
    cd "$FRONTEND_DIR"
    npm install >/dev/null 2>&1 || true
    VITE_API_BASE="${VITE_API_BASE:-http://${BACKEND_HOST}:${BACKEND_PORT}}" npm run dev -- --host "$FRONTEND_HOST"
  ) &
  FRONT_PID=$!
}

wait_for_any_exit() {
  while :; do
    if [[ -n "${BACK_PID:-}" ]] && ! kill -0 "$BACK_PID" 2>/dev/null; then
      return 0
    fi
    if [[ -n "${FRONT_PID:-}" ]] && ! kill -0 "$FRONT_PID" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
}

shutdown_all() {
  if (( SHUTTING_DOWN )); then
    return
  fi
  SHUTTING_DOWN=1
  echo "[dev] shutting down"
  stop_process "${BACK_PID:-}"
  stop_process "${FRONT_PID:-}"
  cleanup_stale_dev_processes
}

trap 'shutdown_all' INT TERM EXIT

cleanup_stale_dev_processes
start_backend
start_frontend

while :; do
  wait_for_any_exit

  if (( SHUTTING_DOWN )); then
    break
  fi

  if [[ -n "${FRONT_PID:-}" ]] && ! kill -0 "$FRONT_PID" 2>/dev/null; then
    echo "[dev] frontend exited; stopping backend"
    shutdown_all
    break
  fi

  if [[ -n "${BACK_PID:-}" ]] && ! kill -0 "$BACK_PID" 2>/dev/null; then
    echo "[dev] backend exited; restarting in 1s"
    sleep 1
    start_backend
  fi
done
