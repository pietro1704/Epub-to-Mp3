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
VENDOR_BASE="${IOS_DIR}/Vendor"
VENDOR_DIR="${VENDOR_BASE}/Python"
SITE_PACKAGES_DIR="${VENDOR_BASE}/site-packages"
STDLIB_OUT="${VENDOR_BASE}/python-stdlib"

mkdir -p "${CACHE_DIR}" "${VENDOR_DIR}" "${SITE_PACKAGES_DIR}"

if [[ ! -f "${CACHE_DIR}/${TARBALL}" ]]; then
  echo "==> Downloading ${URL}"
  curl -fL --retry 3 -o "${CACHE_DIR}/${TARBALL}.tmp" "${URL}"
  mv "${CACHE_DIR}/${TARBALL}.tmp" "${CACHE_DIR}/${TARBALL}"
else
  echo "==> Using cached ${CACHE_DIR}/${TARBALL}"
fi

if [[ ! -d "${VENDOR_DIR}/Python.xcframework" ]]; then
  echo "==> Extracting Python.xcframework into ${VENDOR_DIR}"
  tmp_extract="$(mktemp -d)"
  tar -xzf "${CACHE_DIR}/${TARBALL}" -C "${tmp_extract}"
  cp -R "${tmp_extract}/Python.xcframework" "${VENDOR_DIR}/"
  # b13+ packs the stdlib INSIDE the xcframework under
  #   ios-arm64/lib-arm64/python3.13/
  # and (for the simulator slice)
  #   ios-arm64_x86_64-simulator/lib-arm64_x86_64-simulator/python3.13/
  # We mirror the arm64-device stdlib to VENDOR_DIR/python-stdlib so the
  # Swift bundle has a single PYTHONHOME-friendly path. The simulator slice
  # reads from the framework directly at runtime.
  # Real Python stdlib (os.py, encodings/, json/, etc.) lives at
  # Python.xcframework/lib/python3.X/ — arch-independent .py files.
  STDLIB_SRC="${VENDOR_DIR}/Python.xcframework/lib/python${PY_VERSION}"
  if [[ -d "${STDLIB_SRC}" ]]; then
    cp -R "${STDLIB_SRC}" "${STDLIB_OUT}"
  else
    echo "error: stdlib not found at expected path ${STDLIB_SRC}" >&2
    echo "       tarball layout may have changed; inspect ${tmp_extract}" >&2
    exit 1
  fi
  # Native .so extensions (_socket, _ssl, _hashlib, _asyncio, etc.) are
  # arch-specific. For the spike we bundle the host-matching simulator
  # arch. Real device + universal build needs a fat lib-dynload merged
  # from both arm64 + arm64_simulator slices via lipo, but that's the
  # next phase.
  HOST_ARCH="$(uname -m)"  # arm64 on Apple Silicon, x86_64 on Intel
  DYNLOAD_SRC="${VENDOR_DIR}/Python.xcframework/ios-arm64_x86_64-simulator/lib-${HOST_ARCH}/python${PY_VERSION}/lib-dynload"
  if [[ -d "${DYNLOAD_SRC}" ]]; then
    cp -R "${DYNLOAD_SRC}" "${STDLIB_OUT}/lib-dynload"
  else
    echo "error: lib-dynload not found at ${DYNLOAD_SRC}" >&2
    exit 1
  fi
  rm -rf "${tmp_extract}"
else
  echo "==> Python.xcframework already extracted"
fi

# --- site-packages slim build -------------------------------------------------
# Strategy: install host wheels normally, then DELETE all .so files. aiohttp,
# multidict, yarl, frozenlist, propcache all check for their compiled extension
# at import time and silently fall back to pure-Python siblings (_*.py) when
# the .so is missing. Slower HTTP parsing but cross-platform — same .py files
# work in iOS simulator + device + macOS without any cross-compile.
#
# Why not --no-binary :all: + NO_EXTENSIONS=1 env vars? Setuptools in older
# Pythons rejects modern pyproject.toml license tables, breaking sdist builds.
# Simpler to install binary wheels then strip the .so.
if [[ -z "$(ls -A "${SITE_PACKAGES_DIR}" 2>/dev/null)" ]]; then
  echo "==> Installing edge-tts + aiohttp into ${SITE_PACKAGES_DIR}"
  python3 -m pip install \
    --target "${SITE_PACKAGES_DIR}" \
    --no-compile \
    edge-tts aiohttp
  echo "==> Stripping platform-specific .so files (force pure-Python fallback)"
  find "${SITE_PACKAGES_DIR}" -name "*.so" -delete 2>/dev/null || true
  find "${SITE_PACKAGES_DIR}" -name "*.pyd" -delete 2>/dev/null || true
  find "${SITE_PACKAGES_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "${SITE_PACKAGES_DIR}" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
  # Smoke-test that aiohttp imports cleanly after .so removal.
  PYTHONPATH="${SITE_PACKAGES_DIR}" python3 -c "
import sys
sys.path.insert(0, '${SITE_PACKAGES_DIR}')
import aiohttp, edge_tts
print(f'  aiohttp {aiohttp.__version__}  edge_tts {edge_tts.__version__}  (pure-Python)')
" || {
    echo "error: aiohttp/edge_tts import failed after .so strip" >&2
    echo "       this means some package does not have a pure-Python fallback." >&2
    exit 1
  }
else
  echo "==> site-packages already populated"
fi

echo ""
echo "==> Done. Vendor sizes:"
du -sh "${VENDOR_DIR}/Python.xcframework" "${STDLIB_OUT}" "${SITE_PACKAGES_DIR}" 2>/dev/null || true
echo ""
echo "Next: run 'mise exec -- xcodegen' inside ios/EpubToMp3/, then build/test"
echo "with the EpubToMp3 scheme on an iOS Simulator destination."
