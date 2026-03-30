#!/usr/bin/env bash
# Build the Epub-to-Mp3 desktop app via mise tasks.
# Usage:
#   ./scripts/build_desktop.sh              # full build
#   ./scripts/build_desktop.sh --skip-sidecar
#   ./scripts/build_desktop.sh --skip-web
#   ./scripts/build_desktop.sh --skip-tauri
#
# Prerequisites: mise install (installs Rust + tauri-cli automatically)

set -euo pipefail

SKIP_SIDECAR=false
SKIP_WEB=false
SKIP_TAURI=false

for arg in "$@"; do
  case $arg in
    --skip-sidecar) SKIP_SIDECAR=true ;;
    --skip-web)     SKIP_WEB=true ;;
    --skip-tauri)   SKIP_TAURI=true ;;
  esac
done

echo "==> Epub-to-Mp3 Desktop Build"

if ! $SKIP_SIDECAR; then
  echo "── [1/3] Python sidecar ─────────────────────────────────────"
  mise run desktop:sidecar
fi

if ! $SKIP_WEB; then
  echo "── [2/3] React frontend ─────────────────────────────────────"
  mise run desktop:web
fi

if ! $SKIP_TAURI; then
  echo "── [3/3] Tauri build ────────────────────────────────────────"
  cd desktop && mise exec -- tauri build
  echo ""
  echo "==> Done! Bundle at:"
  echo "    desktop/src-tauri/target/release/bundle/"
fi
