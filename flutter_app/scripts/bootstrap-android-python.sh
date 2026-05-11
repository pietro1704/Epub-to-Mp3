#!/usr/bin/env bash
# Mirror python_app/src/ into the Android Chaquopy source set so the APK
# bundles the pipeline modules at build time. Idempotent: safe to re-run.
#
# Analogue of ios/EpubToMp3/scripts/bootstrap-ios-python.sh — both keep
# the iOS and Android clients on the exact same Python codebase as the
# macOS sidecar / HF Spaces backend.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/python_app/src"
DEST_ROOT="${REPO_ROOT}/flutter_app/android/app/src/main/python"
DEST_PKG="${DEST_ROOT}/python_app"
DEST_SRC="${DEST_PKG}/src"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "error: ${SRC_DIR} not found — did you run this from a fresh checkout?" >&2
  exit 1
fi

echo "[bootstrap-android-python] syncing python_app/src/ → ${DEST_SRC}"

mkdir -p "${DEST_PKG}"
rm -rf "${DEST_SRC}"
mkdir -p "${DEST_SRC}"

# Copy only .py files (exclude __pycache__, .pyc, server.py, anything
# Android can't / shouldn't run). We don't need FastAPI/uvicorn server
# routes inside the app, only the parsing + TTS pipeline.
EXCLUDES=(
  "server.py"
  "_server_*.py"
  "routes_*.py"
  "uploads.py"
)

rsync_excludes=()
for pat in "${EXCLUDES[@]}"; do
  rsync_excludes+=("--exclude=${pat}")
done

if command -v rsync >/dev/null 2>&1; then
  # NOTE: rsync uses first-match-wins. Put excludes BEFORE the broad
  # `--include='*.py'` so server-side modules are actually filtered out.
  rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    "${rsync_excludes[@]}" \
    --include='*/' \
    --include='*.py' \
    --exclude='*' \
    "${SRC_DIR}/" "${DEST_SRC}/"
else
  # Portable fallback (find + cp) for hosts without rsync.
  ( cd "${SRC_DIR}" && find . -name '*.py' -print0 ) | while IFS= read -r -d '' rel; do
    base="$(basename "$rel")"
    skip=0
    for pat in "${EXCLUDES[@]}"; do
      case "$base" in
        $pat) skip=1; break ;;
      esac
    done
    [[ $skip -eq 1 ]] && continue
    dest="${DEST_SRC}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp "${SRC_DIR}/${rel}" "$dest"
  done
fi

# Ensure the python_app and python_app.src packages are importable from
# Kotlin via Chaquopy's `py.getModule("python_app.src.android_entrypoints")`.
touch "${DEST_PKG}/__init__.py"
touch "${DEST_SRC}/__init__.py"

echo "[bootstrap-android-python] done — $(find "${DEST_SRC}" -name '*.py' | wc -l | tr -d ' ') .py files"
