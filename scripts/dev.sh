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
BACKEND_WATCH_PID=""
SHUTTING_DOWN=0
BACKEND_RESTART_FLAG="${TMPDIR:-/tmp}/epub_to_mp3_backend_restart.flag"

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

backend_watch_targets() {
  local target=""
  for target in \
    "$PROJECT_ROOT/python_app" \
    "$PROJECT_ROOT/hf_app.py" \
    "$PROJECT_ROOT/convert"
  do
    [[ -e "$target" ]] && printf '%s\n' "$target"
  done
}

backend_watch_files() {
  if command -v rg >/dev/null 2>&1; then
    (
      cd "$PROJECT_ROOT"
      rg --files python_app \
        -g '*.py' \
        -g '*.json' \
        -g '*.yaml' \
        -g '*.yml'
    )
  else
    find "$PROJECT_ROOT/python_app" -type f \
      \( -name '*.py' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) \
      -print | sed "s#^$PROJECT_ROOT/##"
  fi
  [[ -f "$PROJECT_ROOT/hf_app.py" ]] && printf '%s\n' 'hf_app.py'
  [[ -f "$PROJECT_ROOT/convert" ]] && printf '%s\n' 'convert'
}

backend_watch_signature() {
  (
    cd "$PROJECT_ROOT"
    backend_watch_files | while read -r relative_path; do
      [[ -n "$relative_path" ]] || continue
      if [[ -e "$relative_path" ]]; then
        stat -f '%m %N' "$relative_path" 2>/dev/null || true
      fi
    done
  ) | sort
}

backend_restart_requested() {
  [[ -f "$BACKEND_RESTART_FLAG" ]]
}

request_backend_restart() {
  : > "$BACKEND_RESTART_FLAG"
}

clear_backend_restart_request() {
  rm -f "$BACKEND_RESTART_FLAG"
}

start_backend_watcher() {
  stop_process "${BACKEND_WATCH_PID:-}"
  clear_backend_restart_request
  (
    local previous_signature=""
    local current_signature=""
    sleep 2
    previous_signature="$(backend_watch_signature)"
    while :; do
      sleep 2
      current_signature="$(backend_watch_signature)"
      if [[ "$current_signature" != "$previous_signature" ]]; then
        echo "[dev] backend file change detected; scheduling restart"
        previous_signature="$current_signature"
        request_backend_restart
      fi
    done
  ) &
  BACKEND_WATCH_PID=$!
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

frontend_needs_install() {
  local node_modules_dir="$PROJECT_ROOT/$FRONTEND_DIR/node_modules"
  local lockfile="$PROJECT_ROOT/$FRONTEND_DIR/package-lock.json"
  [[ -d "$node_modules_dir" ]] || return 0
  [[ -f "$lockfile" ]] || return 1
  [[ "$lockfile" -nt "$node_modules_dir" ]]
}

start_frontend() {
  echo "[dev] starting frontend on ${FRONTEND_HOST}"
  (
    cd "$FRONTEND_DIR"
    if frontend_needs_install; then
      echo "[dev] installing frontend dependencies"
      npm install
    fi
    VITE_API_BASE="${VITE_API_BASE:-http://${BACKEND_HOST}:${BACKEND_PORT}}" npm run dev -- --host "$FRONTEND_HOST"
  ) &
  FRONT_PID=$!
}

wait_for_any_exit() {
  while :; do
    if backend_restart_requested; then
      return 0
    fi
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
  clear_backend_restart_request
  stop_process "${BACK_PID:-}"
  stop_process "${FRONT_PID:-}"
  stop_process "${BACKEND_WATCH_PID:-}"
  cleanup_stale_dev_processes
}

handle_signal() {
  shutdown_all
  trap - EXIT
  exit 0
}

trap 'handle_signal' INT TERM
trap 'shutdown_all' EXIT

cleanup_stale_dev_processes
start_backend
start_backend_watcher
start_frontend

while :; do
  wait_for_any_exit

  if (( SHUTTING_DOWN )); then
    break
  fi

  if backend_restart_requested; then
    echo "[dev] restarting backend after file change"
    clear_backend_restart_request
    stop_process "${BACK_PID:-}"
    start_backend
    continue
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
