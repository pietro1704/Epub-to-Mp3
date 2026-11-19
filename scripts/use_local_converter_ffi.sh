#!/usr/bin/env bash
# Xcode post-build step for the local Debug macOS loop.
#
# Without EPUB2MP3_LOCAL_FFI_DYLIB this is a no-op for every build that never
# used the local route, so CI, packaging and Release keep embedding exactly
# target/release/libconverter_ffi.dylib through the project copy phase.
# With it (passed only by `mise run mac:test:local`), a Debug macOS build embeds
# target/local-dev/release/libconverter_ffi.dylib instead. Any other configuration,
# platform or path is refused.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
requested="${EPUB2MP3_LOCAL_FFI_DYLIB:-}"
if [[ "${PLATFORM_NAME:-}" != macosx ]]; then
  if [[ -n "$requested" ]]; then
    echo "error: EPUB2MP3_LOCAL_FFI_DYLIB is accepted only for macOS builds, not ${PLATFORM_NAME:-unknown}" >&2
    exit 1
  fi
  exit 0
fi
embedded="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/libconverter_ffi.dylib"
marker="${DERIVED_FILE_DIR:?}/local-converter-ffi.embedded"

sign_embedded() {
  if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$embedded"
  fi
}

if [[ -z "$requested" ]]; then
  # Xcode reruns its copy phase only when the release input changes, so undo a
  # previous local override in this DerivedData before reporting success.
  if [[ -f "$marker" ]]; then
    cp "$root/target/release/libconverter_ffi.dylib" "$embedded"
    sign_embedded
    rm -f "$marker"
    echo "Restored target/release converter-ffi after a local-dev build"
  fi
  exit 0
fi

if [[ "${CONFIGURATION:-}" != Debug ]]; then
  echo "error: EPUB2MP3_LOCAL_FFI_DYLIB is accepted only for Debug builds, not ${CONFIGURATION:-unknown}" >&2
  exit 1
fi
expected="$root/target/local-dev/release/libconverter_ffi.dylib"
if [[ ! -f "$requested" || -L "$requested" || ! -f "$expected" ||
      "$(cd "$(dirname "$requested")" && pwd -P)/$(basename "$requested")" != "$(cd "$(dirname "$expected")" && pwd -P)/libconverter_ffi.dylib" ]]; then
  echo "error: EPUB2MP3_LOCAL_FFI_DYLIB must be the built $expected" >&2
  exit 1
fi
if ! cmp -s "$requested" "$embedded"; then
  cp "$requested" "$embedded"
  sign_embedded
fi
mkdir -p "$(dirname "$marker")"
printf '%s\n' "$expected" > "$marker"
echo "Embedded local-dev converter-ffi (not a release artifact): $expected"
