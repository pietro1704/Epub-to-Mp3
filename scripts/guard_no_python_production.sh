#!/usr/bin/env bash
set -euo pipefail

# Production artifacts must not contain the legacy Python runtime or bridge.
# Source compatibility remains allowed until the Rust replacement lands for
# every client; this guard only scans packaging manifests and release inputs.

forbidden=(
  'python_app/'
  'hf_app.py'
  'requirements.txt'
  'requirements-desktop.txt'
  'PyInstaller'
  'Python.xcframework'
  'bootstrap-ios-python.sh'
  'bootstrap-android-python.sh'
  'bootstrap-desktop-python.sh'
  'setup-python@'
  'actions/setup-python@'
  'python:3.'
)

files=(Dockerfile mise.toml .github/workflows .dockerignore)
if [[ "${ALLOW_LEGACY_PYTHON_PACKAGING:-}" == "1" ]]; then
  echo "legacy Python packaging guard override is not permitted in CI" >&2
  exit 1
fi
for pattern in "${forbidden[@]}"; do
  if git grep -n -E -- "$pattern" -- "${files[@]}"; then
    echo "production packaging still references legacy Python: $pattern" >&2
    exit 1
  fi
done

echo "production packaging contains no legacy Python runtime or bridge references"
