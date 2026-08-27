#!/usr/bin/env bash
# Select CPython binary modules from the exact XCFramework slice being built.
# Xcode runs this after Copy Bundle Resources, so each built app receives the
# device, simulator, or macOS `lib-dynload` matching its own app binary.
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.13}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCF="${IOS_DIR}/Vendor/Python/Python.xcframework"
STDLIB_SOURCE="${IOS_DIR}/Vendor/python-stdlib"
# `PLATFORM_NAME` can reflect a secondary destination while a universal
# target is being built. `EFFECTIVE_PLATFORM_NAME` is tied to the current
# product directory (`-iphoneos`, `-iphonesimulator`, or empty on macOS),
# so prefer it when Xcode provides it.
EFFECTIVE_PLATFORM_NAME_VALUE="${EFFECTIVE_PLATFORM_NAME:-}"
EFFECTIVE_PLATFORM="${EFFECTIVE_PLATFORM_NAME_VALUE#-}"
PLATFORM="${EFFECTIVE_PLATFORM:-${PLATFORM_NAME:-${1:-}}}"
TARGET_ARCHS="${ARCHS:-${2:-$(uname -m)}}"
RESOURCE_ROOT="${TARGET_BUILD_DIR:+${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}}"

if [[ ! -d "${XCF}" || ! -d "${STDLIB_SOURCE}" ]]; then
  echo "error: bootstrap-ios-python.sh must create Python.xcframework and python-stdlib first" >&2
  exit 1
fi
if [[ -z "${RESOURCE_ROOT}" || ! -d "${RESOURCE_ROOT}/python-stdlib" ]]; then
  echo "error: Xcode must run this after python-stdlib has been copied to app resources" >&2
  exit 1
fi

case "${PLATFORM}" in
  iphoneos)
    SOURCE="${XCF}/ios-arm64/lib-arm64/python${PY_VERSION}/lib-dynload"
    TARGET="iphoneos-arm64"
    ;;
  iphonesimulator)
    if [[ " ${TARGET_ARCHS} " == *" x86_64 "* ]]; then
      ARCH="x86_64"
    else
      ARCH="arm64"
    fi
    SOURCE="${XCF}/ios-arm64_x86_64-simulator/lib-${ARCH}/python${PY_VERSION}/lib-dynload"
    TARGET="iphonesimulator-${ARCH}"
    ;;
  macosx)
    SOURCE="${XCF}/macos-arm64_x86_64/Python.framework/Versions/${PY_VERSION}/lib/python${PY_VERSION}/lib-dynload"
    TARGET="macos-universal"
    ;;
  *)
    echo "error: unsupported Apple platform '${PLATFORM:-unset}'" >&2
    echo "       pass PLATFORM_NAME=iphoneos, iphonesimulator, or macosx" >&2
    exit 1
    ;;
esac

if [[ ! -d "${SOURCE}" ]]; then
  echo "error: matching CPython binary-module slice is missing: ${SOURCE}" >&2
  exit 1
fi

MARKER="${RESOURCE_ROOT}/python-stdlib/.embedded-python-runtime-target"
DESTINATION="${RESOURCE_ROOT}/python-stdlib/lib-dynload"
if [[ -f "${MARKER}" ]] && [[ "$(<"${MARKER}")" == "${TARGET}" ]] && [[ -d "${DESTINATION}" ]]; then
  echo "==> CPython binary modules already match ${TARGET}"
  exit 0
fi

if [[ -d "${DESTINATION}" ]]; then
  rm -rf -- "${DESTINATION}"
fi
cp -R "${SOURCE}" "${DESTINATION}"

# iOS enforces code signatures on every dynamically loaded native module.
# These CPython extensions are copied into the app resources after Xcode's
# resource phase, so sign the device slice before the target's final bundle
# signature is created. Simulator and macOS builds do not need this step.
if [[ "${PLATFORM}" == "iphoneos" ]] \
    && [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]] \
    && [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  while IFS= read -r -d '' module; do
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      --timestamp=none "${module}"
  done < <(find "${DESTINATION}" -type f -name "*.so" -print0)
  echo "==> Signed CPython binary modules for iPhone device"
fi

printf '%s\n' "${TARGET}" > "${MARKER}"
echo "==> Bundled CPython binary modules for ${TARGET}"
