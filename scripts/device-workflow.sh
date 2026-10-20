#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/ios/EpubToMp3/.build/device-workflow"
BINARY="$CACHE/debug/device-workflow"
ACTION="${1:-status}"
[[ "$#" -eq 0 ]] || shift
export DEVICE_WORKFLOW_ROOT="$ROOT" DEVICE_WORKFLOW_CACHE="$CACHE"
export IOS_DISK_GUARD_ACTIVE_BUILD_DIR="$ROOT/ios/EpubToMp3/.build"

build_native() {
  local mode="$1"
  local arguments=(swift "$mode" --package-path "$ROOT/tools/DeviceWorkflow"
                   --scratch-path "$CACHE" --jobs 1)
  if [[ "$mode" == "build" ]]; then
    arguments+=(--product device-workflow)
  fi
  mise exec -- ruby "$ROOT/scripts/native_job.rb" build -- xcrun "${arguments[@]}"
}

case "$ACTION" in
  prepare)
    build_native build
    exit 0
    ;;
  host-tests)
    build_native test
    exit 0
    ;;
esac

preparation_required() {
  echo "Device workflow CLI is missing, stale, or cannot be verified; run scripts/device-workflow.sh prepare explicitly." >&2
  exit 1
}

[[ -x "$BINARY" ]] || preparation_required
# Missing inputs and failed traversal must fail closed, not reuse an unchecked CLI.
[[ -d "$ROOT/tools/DeviceWorkflow/Sources" && -f "$ROOT/tools/DeviceWorkflow/Package.swift" ]] || preparation_required
if ! newer_sources="$(find "$ROOT/tools/DeviceWorkflow/Sources" "$ROOT/tools/DeviceWorkflow/Package.swift" -name '*.swift' -newer "$BINARY" -print)"; then
  preparation_required
fi
[[ -z "$newer_sources" ]] || preparation_required

cd "$ROOT"
exec "$BINARY" "$ACTION" "$@"
