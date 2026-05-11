#!/usr/bin/env bash
# Bootstrap Python.xcframework + stdlib + minimal site-packages for the
# iOS embedded-Python spike (branch: feat/ios-python-embed).
#
# Caches the Beeware tarball under ~/.cache/epub-to-mp3/python-apple-support/
# so repeated invocations (CI, local rebuilds) don't redownload ~80 MB.
#
# Vendor output (gitignored, ~150 MB):
#   ios/EpubToMp3/Vendor/Python/Python.xcframework
#   ios/EpubToMp3/Vendor/Python/python-stdlib/
#   ios/EpubToMp3/Vendor/site-packages/
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.13}"
PY_BUILD="${PY_BUILD:-b13}"
TAG="${PY_VERSION}-${PY_BUILD}"
TARBALL="Python-${PY_VERSION}-iOS-support.${PY_BUILD}.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${TAG}/${TARBALL}"

CACHE_DIR="${HOME}/.cache/epub-to-mp3/python-apple-support"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${IOS_DIR}/EpubToMp3/Vendor/Python"
SITE_PACKAGES_DIR="${IOS_DIR}/EpubToMp3/Vendor/site-packages"

mkdir -p "${CACHE_DIR}" "${VENDOR_DIR}" "${SITE_PACKAGES_DIR}"

if [[ ! -f "${CACHE_DIR}/${TARBALL}" ]]; then
  echo "==> Downloading ${URL}"
  curl -fL --retry 3 -o "${CACHE_DIR}/${TARBALL}.tmp" "${URL}"
  mv "${CACHE_DIR}/${TARBALL}.tmp" "${CACHE_DIR}/${TARBALL}"
else
  echo "==> Using cached ${CACHE_DIR}/${TARBALL}"
fi

if [[ ! -d "${VENDOR_DIR}/Python.xcframework" ]]; then
  echo "==> Extracting Python.xcframework + stdlib into ${VENDOR_DIR}"
  tmp_extract="$(mktemp -d)"
  tar -xzf "${CACHE_DIR}/${TARBALL}" -C "${tmp_extract}"
  # Beeware tarball top level: Python.xcframework + python-stdlib
  cp -R "${tmp_extract}/Python.xcframework" "${VENDOR_DIR}/"
  cp -R "${tmp_extract}/python-stdlib" "${VENDOR_DIR}/"
  rm -rf "${tmp_extract}"
else
  echo "==> Python.xcframework already extracted"
fi

# --- site-packages slim build -------------------------------------------------
# Spike strategy: install pure-Python deps and macOS ARM64 wheels for the
# C-ext deps (works in iOS simulator on Apple Silicon; NOT on real device).
# Real-device requires kivy-ios/cibuildwheel cross-compile — out of scope.
if [[ -z "$(ls -A "${SITE_PACKAGES_DIR}" 2>/dev/null)" ]]; then
  echo "==> Installing edge-tts + aiohttp into ${SITE_PACKAGES_DIR}"
  python3 -m pip install \
    --target "${SITE_PACKAGES_DIR}" \
    --python-version "${PY_VERSION}" \
    --only-binary=:all: \
    --no-compile \
    edge-tts aiohttp || {
      echo "warn: --only-binary failed (likely sdist deps); retrying without restriction" >&2
      python3 -m pip install \
        --target "${SITE_PACKAGES_DIR}" \
        --no-compile \
        edge-tts aiohttp
  }
  # Strip __pycache__, dist-info bloat
  find "${SITE_PACKAGES_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "${SITE_PACKAGES_DIR}" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
else
  echo "==> site-packages already populated"
fi

echo ""
echo "==> Done. Vendor sizes:"
du -sh "${VENDOR_DIR}/Python.xcframework" "${VENDOR_DIR}/python-stdlib" "${SITE_PACKAGES_DIR}" 2>/dev/null || true
echo ""
echo "Next: run 'mise exec -- xcodegen' inside ios/EpubToMp3/, then build/test"
echo "with the EpubToMp3 scheme on an iOS Simulator destination."
