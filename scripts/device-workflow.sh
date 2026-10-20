#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/ios/EpubToMp3/.build/device-workflow"
BINARY="$CACHE/debug/device-workflow"
ACTION="${1:-status}"
[[ "$#" -eq 0 ]] || shift
export DEVICE_WORKFLOW_ROOT="$ROOT" DEVICE_WORKFLOW_CACHE="$CACHE"
export IOS_DISK_GUARD_ACTIVE_BUILD_DIR="$ROOT/ios/EpubToMp3/.build"

# Passive verification uses an already installed interpreter, never a launcher.
RECEIPT_RUBY="${DEVICE_WORKFLOW_RUBY:-$(command -v ruby || true)}"
case "$RECEIPT_RUBY" in
  /usr/bin/ruby|/bin/ruby|*/shims/*|"")
    echo "Set DEVICE_WORKFLOW_RUBY to an installed Ruby executable (no shim)." >&2
    exit 1
    ;;
esac
[[ "$RECEIPT_RUBY" == /* && -x "$RECEIPT_RUBY" ]] || exit 1
if [[ "$RECEIPT_RUBY" -ef /usr/bin/ruby ]]; then
  echo "Set DEVICE_WORKFLOW_RUBY to an installed Ruby executable (no shim)." >&2
  exit 1
fi

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
    mise exec -- ruby "$ROOT/scripts/native_job.rb" build -- bash -euo pipefail -s -- "$ROOT" "$CACHE" "$RECEIPT_RUBY" <<'PREPARE'
root="$1"
cache="$2"
receipt_ruby="$3"
source_identity="$("$receipt_ruby" "$root/scripts/device_workflow_receipt.rb" snapshot "$root")"
xcrun swift build --package-path "$root/tools/DeviceWorkflow" --scratch-path "$cache" --jobs 1 --product device-workflow
"$receipt_ruby" "$root/scripts/device_workflow_receipt.rb" record "$root" "$source_identity"
PREPARE
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

"$RECEIPT_RUBY" "$ROOT/scripts/device_workflow_receipt.rb" verify "$ROOT" || preparation_required

cd "$ROOT"
exec "$BINARY" "$ACTION" "$@"
