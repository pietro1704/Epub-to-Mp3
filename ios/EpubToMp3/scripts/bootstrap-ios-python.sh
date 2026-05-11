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
IOS_TARBALL="Python-${PY_VERSION}-iOS-support.${PY_BUILD}.tar.gz"
MACOS_TARBALL="Python-${PY_VERSION}-macOS-support.${PY_BUILD}.tar.gz"
IOS_URL="https://github.com/beeware/Python-Apple-support/releases/download/${TAG}/${IOS_TARBALL}"
MACOS_URL="https://github.com/beeware/Python-Apple-support/releases/download/${TAG}/${MACOS_TARBALL}"

CACHE_DIR="${HOME}/.cache/epub-to-mp3/python-apple-support"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_BASE="${IOS_DIR}/Vendor"
VENDOR_DIR="${VENDOR_BASE}/Python"
SITE_PACKAGES_DIR="${VENDOR_BASE}/site-packages"
STDLIB_OUT="${VENDOR_BASE}/python-stdlib"

mkdir -p "${CACHE_DIR}" "${VENDOR_DIR}" "${SITE_PACKAGES_DIR}"

download_if_missing() {
  local url="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    echo "==> Downloading $url"
    curl -fL --retry 3 -o "${path}.tmp" "$url"
    mv "${path}.tmp" "$path"
  else
    echo "==> Using cached $path"
  fi
}
download_if_missing "${IOS_URL}" "${CACHE_DIR}/${IOS_TARBALL}"
download_if_missing "${MACOS_URL}" "${CACHE_DIR}/${MACOS_TARBALL}"

if [[ ! -d "${VENDOR_DIR}/Python.xcframework" ]]; then
  echo "==> Building Python.xcframework with iOS + macOS slices"
  tmp_extract="$(mktemp -d)"
  mkdir -p "${tmp_extract}/ios" "${tmp_extract}/macos"
  tar -xzf "${CACHE_DIR}/${IOS_TARBALL}" -C "${tmp_extract}/ios"
  tar -xzf "${CACHE_DIR}/${MACOS_TARBALL}" -C "${tmp_extract}/macos"
  # Start from the iOS xcframework (it has the aux lib/, lib-arm64/,
  # lib-x86_64/ trees alongside the framework slices — Beeware uses
  # those for stdlib + lib-dynload at runtime). Then graft the macOS
  # slice into the same xcframework so the linker has a slice on
  # every build flavour of the SwiftUI target. `xcodebuild
  # -create-xcframework` would discard the aux dirs, so we splice
  # manually via Info.plist editing + filesystem copies.
  cp -R "${tmp_extract}/ios/Python.xcframework" "${VENDOR_DIR}/"
  # Copy macOS slice contents.
  cp -R "${tmp_extract}/macos/Python.xcframework/macos-arm64_x86_64" \
        "${VENDOR_DIR}/Python.xcframework/"
  # Append macOS entry to AvailableLibraries in Info.plist.
  python3 - <<PYEOF
import plistlib, pathlib
p = pathlib.Path("${VENDOR_DIR}/Python.xcframework/Info.plist")
data = plistlib.loads(p.read_bytes())
data["AvailableLibraries"].append({
    "BinaryPath": "Python.framework/Versions/3.13/Python",
    "LibraryIdentifier": "macos-arm64_x86_64",
    "LibraryPath": "Python.framework",
    "SupportedArchitectures": ["arm64", "x86_64"],
    "SupportedPlatform": "macos",
})
p.write_bytes(plistlib.dumps(data))
print("==> Patched Info.plist with macOS slice")
PYEOF
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
# After the Swift EdgeTTSBridge (URLSession + URLSessionWebSocketTask) took
# over Edge-TTS networking, Python no longer needs aiohttp / edge_tts /
# _socket / _ssl on iOS. site-packages stays present but empty for the
# network deps. We DO embed `python_app/src/` so the canonical EPUB
# parser (`ebook_reader.parse_epub_to_dict`) and other pure-stdlib
# helpers are importable from PythonBridge.swift — the same code the
# macOS sidecar and HF Spaces backend run, no Swift reimplementation.
mkdir -p "${SITE_PACKAGES_DIR}"
# Drop any pre-existing aiohttp/edge_tts install from older spike runs.
for pkg in aiohttp aiohappyeyeballs aiosignal attr attrs certifi edge_playback \
           edge_tts frozenlist idna multidict propcache tabulate yarl bin; do
  rm -rf "${SITE_PACKAGES_DIR}/${pkg}" 2>/dev/null || true
done
rm -f "${SITE_PACKAGES_DIR}/typing_extensions.py" 2>/dev/null || true
find "${SITE_PACKAGES_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "${SITE_PACKAGES_DIR}" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true

# --- python_app embed --------------------------------------------------------
# Copy only the bits the iOS app actually imports. We deliberately skip:
#   - server.py / hf_app.py / desktop_main.py (FastAPI/uvicorn pull aiohttp)
#   - main.py (CLI entry point)
#   - tests/ scripts/ requirements.txt
# The pure-stdlib parser modules (ebook_reader, text_formatting,
# cache_manager, paths) ship as-is; native-dep modules under src/tts/
# are kept off the path on iOS (we route synthesis through Swift).
PYAPP_SRC="${IOS_DIR}/../../python_app"
PYAPP_DEST="${SITE_PACKAGES_DIR}/python_app"
if [[ -d "${PYAPP_SRC}" ]]; then
  echo "==> Embedding python_app/src into ${PYAPP_DEST}"
  rm -rf "${PYAPP_DEST}"
  mkdir -p "${PYAPP_DEST}"
  # __init__.py is required so `import python_app` resolves.
  if [[ -f "${PYAPP_SRC}/__init__.py" ]]; then
    cp "${PYAPP_SRC}/__init__.py" "${PYAPP_DEST}/"
  else
    touch "${PYAPP_DEST}/__init__.py"
  fi
  # Mirror only src/. Strip __pycache__ on the way out so the bundle
  # stays small and reproducible.
  cp -R "${PYAPP_SRC}/src" "${PYAPP_DEST}/src"
  find "${PYAPP_DEST}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
fi

# NOTE: we deliberately leave lib-dynload/*.so in place. iOS refuses to
# `dlopen` them outside a .framework, but CPython only triggers that dlopen
# when an `import` actually references the module. Since the Swift bridge
# owns all networking we never `import socket` / `_socket` / `_ssl` from
# Python, so the broken .so files sit harmlessly on disk. Real-device
# universal builds will need to wrap each .so in its own framework, but
# that's an orthogonal piece of work tracked in PYTHON-EMBED.md.
# A placeholder file inside the site-packages dir so xcodegen's folder-ref
# stays valid (an empty dir gets pruned by some Xcode setups).
echo "# Edge-TTS now uses the Swift bridge; this dir is intentionally empty." \
  > "${SITE_PACKAGES_DIR}/README.txt"

echo ""
echo "==> Done. Vendor sizes:"
du -sh "${VENDOR_DIR}/Python.xcframework" "${STDLIB_OUT}" "${SITE_PACKAGES_DIR}" 2>/dev/null || true
echo ""
echo "Next: run 'mise exec -- xcodegen' inside ios/EpubToMp3/, then build/test"
echo "with the EpubToMp3 scheme on an iOS Simulator destination."
