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

if [[ "$ACTION" == "host-tests" ]]; then
  build_native test
  exit 0
fi

if [[ ! -x "$BINARY" ]] || [[ -n "$(find "$ROOT/tools/DeviceWorkflow/Sources" "$ROOT/tools/DeviceWorkflow/Package.swift" -name '*.swift' -newer "$BINARY" -print -quit 2>/dev/null)" ]]; then
  build_native build
fi
cd "$ROOT"
exec "$BINARY" "$ACTION" "$@"
