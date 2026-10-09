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
  export DEVICE_WORKFLOW_BUILD_MODE="$1"
  # The bootstrap compiler is native; the actual SwiftPM job owns the same
  # shared lease as device work and other repository heavy-job guards.
  xcrun swift -e '
    import Foundation
    import Darwin
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["DEVICE_WORKFLOW_ROOT"],
          let cache = environment["DEVICE_WORKFLOW_CACHE"],
          let mode = environment["DEVICE_WORKFLOW_BUILD_MODE"] else { exit(2) }
    let lease = open("/tmp/epub2mp3.heavy-job.lock", O_CREAT | O_RDWR, 0o600)
    guard lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0 else {
      fputs("Another heavy job is running; inspect its handle before retrying.\n", stderr)
      exit(75)
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    child.currentDirectoryURL = URL(fileURLWithPath: root)
    var arguments = ["swift", mode, "--package-path", root + "/tools/DeviceWorkflow",
                     "--scratch-path", cache, "--jobs", "1"]
    if mode == "build" { arguments += ["--product", "device-workflow"] }
    child.arguments = arguments
    do {
      try child.run()
      child.waitUntilExit()
      close(lease)
      exit(child.terminationStatus)
    } catch {
      fputs("Native workflow build failed: \(error)\n", stderr)
      close(lease)
      exit(1)
    }
  '
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
