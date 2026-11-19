#!/usr/bin/env bash
set -euo pipefail

BACKEND_PORT="${BACKEND_PORT:-8000}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_RELOAD="${BACKEND_RELOAD:-0}"
# The web client is the Rails app in ruby_app/rails_gateway; conversion runs in the browser.
# The Rust converter server is an optional compatibility API: DEV_RUST_SERVER=1 starts it and
# points the Rails app at it through RUST_CONVERTER_URL.
DEV_RUST_SERVER="${DEV_RUST_SERVER:-0}"
WEB_HOST="${WEB_HOST:-127.0.0.1}"
WEB_PORT="${WEB_PORT:-3000}"
WEB_DIR="ruby_app/rails_gateway"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACK_PID=""
WEB_PID=""
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
  cleanup_port_listeners "$BACKEND_PORT" 'cargo run .*converter-server|converter-server'
  cleanup_matching_processes 'cargo run .*converter-server|converter-server'
  cleanup_port_listeners "$WEB_PORT" 'puma|bin/rails'
  cleanup_matching_processes 'puma.*rails_gateway|rails_gateway.*bin/rails server'
}

backend_watch_targets() {
  local target=""
  for target in \
    "$PROJECT_ROOT/crates/converter-core" \
    "$PROJECT_ROOT/crates/converter-server" \
    "$PROJECT_ROOT/crates/converter-ffi"
  do
    [[ -e "$target" ]] && printf '%s\n' "$target"
  done
}

backend_watch_files() {
  if command -v rg >/dev/null 2>&1; then
    (
      cd "$PROJECT_ROOT"
      rg --files crates -g '*.rs' -g '*.toml'
    )
  else
    find "$PROJECT_ROOT/crates" -type f \
      \( -name '*.rs' -o -name '*.toml' \) \
      -print | sed "s#^$PROJECT_ROOT/##"
  fi
}

backend_watch_signature() {
  (
    cd "$PROJECT_ROOT"
    backend_watch_files | while read -r relative_path; do
      [[ -n "$relative_path" ]] || continue
      if [[ -e "$relative_path" ]]; then
        stat -c '%Y %n' "$relative_path" 2>/dev/null || true
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
  local reload=0
  if [[ "$BACKEND_RELOAD" == "1" || "$BACKEND_RELOAD" == "true" || "$BACKEND_RELOAD" == "yes" ]]; then
    reload=1
  fi
  echo "[dev] building and starting backend on http://$BACKEND_HOST:$BACKEND_PORT"
  env BACKEND_HOST="$BACKEND_HOST" BACKEND_PORT="$BACKEND_PORT" BACKEND_RELOAD="$reload" \
    bash "$PROJECT_ROOT/scripts/dev_backend.sh" &
  BACK_PID=$!
}

start_web() {
  echo "[dev] starting the Rails web client on http://${WEB_HOST}:${WEB_PORT}"
  (
    cd "$PROJECT_ROOT/$WEB_DIR"
    if ! mise exec -- bundle check >/dev/null 2>&1; then
      echo "[dev] installing gems"
      mise exec -- bundle install
    fi
    mise exec -- bin/rails db:prepare >/dev/null
    if [[ ! -f config/runtime_manifest.json ]]; then
      echo "[dev] no generated runtime tree: run 'mise run rails:web:runtime-build' for the real browser runtime"
    fi
    if [[ "$DEV_RUST_SERVER" == "1" ]]; then
      export RUST_CONVERTER_URL="${RUST_CONVERTER_URL:-http://${BACKEND_HOST}:${BACKEND_PORT}}"
    fi
    exec mise exec -- bin/rails server -b "$WEB_HOST" -p "$WEB_PORT"
  ) &
  WEB_PID=$!
}

wait_for_any_exit() {
  while :; do
    if backend_restart_requested; then
      return 0
    fi
    if [[ -n "${BACK_PID:-}" ]] && ! kill -0 "$BACK_PID" 2>/dev/null; then
      return 0
    fi
    if [[ -n "${WEB_PID:-}" ]] && ! kill -0 "$WEB_PID" 2>/dev/null; then
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
  stop_process "${WEB_PID:-}"
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
if [[ "$DEV_RUST_SERVER" == "1" ]]; then
  start_backend
  start_backend_watcher
fi
start_web

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

  if [[ -n "${WEB_PID:-}" ]] && ! kill -0 "$WEB_PID" 2>/dev/null; then
    echo "[dev] web client exited; stopping"
    shutdown_all
    break
  fi

  if [[ -n "${BACK_PID:-}" ]] && ! kill -0 "$BACK_PID" 2>/dev/null; then
    echo "[dev] backend exited; restarting in 1s"
    sleep 1
    start_backend
  fi
done
