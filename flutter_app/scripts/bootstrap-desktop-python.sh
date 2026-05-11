#!/usr/bin/env bash
# Mirror python_app/src/ into flutter_app/assets/python_app/src/ so the
# Linux / Windows Flutter desktop bundles ship the parsing pipeline as
# Flutter assets. Idempotent: safe to re-run.
#
# Sibling of bootstrap-android-python.sh — same exclusion list, just a
# different destination because Flutter assets must live under the
# Flutter project root (pubspec.yaml asset paths are relative).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/python_app/src"
DEST_ROOT="${REPO_ROOT}/flutter_app/assets/python_app"
DEST_SRC="${DEST_ROOT}/src"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "error: ${SRC_DIR} not found — did you run this from a fresh checkout?" >&2
  exit 1
fi

echo "[bootstrap-desktop-python] syncing python_app/src/ → ${DEST_SRC}"

mkdir -p "${DEST_ROOT}"
rm -rf "${DEST_SRC}"
mkdir -p "${DEST_SRC}"

# Same exclusion list as the Android bootstrap — desktop runs the
# parsing pipeline only, not the FastAPI server routes.
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
  rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    "${rsync_excludes[@]}" \
    --include='*/' \
    --include='*.py' \
    --exclude='*' \
    "${SRC_DIR}/" "${DEST_SRC}/"
else
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

# Make python_app and python_app.src importable when PYTHONPATH points
# at the extracted asset directory.
touch "${DEST_ROOT}/__init__.py"
touch "${DEST_SRC}/__init__.py"

echo "[bootstrap-desktop-python] done — $(find "${DEST_SRC}" -name '*.py' | wc -l | tr -d ' ') .py files"
