#!/usr/bin/env bash
set -euo pipefail

ROOT="${MISE_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ARTIFACT="${CONVERTER_FFI_IOS_ARTIFACT:-$ROOT/target/aarch64-apple-ios/release/libconverter_ffi.dylib}"
EXPECTED_ARCH="${CONVERTER_FFI_IOS_ARCH:-arm64}"
EXPECTED_PLATFORM="${CONVERTER_FFI_IOS_PLATFORM:-2}"
case "$EXPECTED_ARCH:$EXPECTED_PLATFORM" in
  arm64:2|arm64:7|x86_64:7) ;;
  *) echo "converter-ffi iOS verification error: unsupported architecture/platform" >&2; exit 2 ;;
esac

if [[ ! -f "$ARTIFACT" ]]; then
  echo "converter-ffi iOS verification error: missing $ARTIFACT" >&2
  exit 2
fi

FILE_INFO=$(file "$ARTIFACT")
echo "$FILE_INFO"
grep -q "Mach-O" <<<"$FILE_INFO" || { echo "converter-ffi iOS verification error: not a Mach-O library" >&2; exit 2; }
grep -q "dynamically linked shared library" <<<"$FILE_INFO" || { echo "converter-ffi iOS verification error: not a dylib" >&2; exit 2; }
[[ "$(lipo -archs "$ARTIFACT")" == "$EXPECTED_ARCH" ]] || { echo "converter-ffi iOS verification error: expected single $EXPECTED_ARCH architecture" >&2; exit 2; }

SYMBOLS=$(nm -arch "$EXPECTED_ARCH" -gU "$ARTIFACT")
for SYMBOL in converter_session_open converter_session_metadata_json converter_session_free \
  converter_string_free converter_last_error converter_tts_models_json \
  converter_tts_default_engine converter_session_convert_json; do
  grep -q "_$SYMBOL$" <<<"$SYMBOLS" || {
    echo "converter-ffi iOS verification error: missing exported symbol $SYMBOL" >&2; exit 2;
  }
done

BUILD_COMMANDS=$(otool -arch "$EXPECTED_ARCH" -l "$ARTIFACT")
grep -A4 "LC_BUILD_VERSION" <<<"$BUILD_COMMANDS" | grep -Eq "platform[[:space:]]+$EXPECTED_PLATFORM$" || {
  echo "converter-ffi iOS verification error: wrong Apple platform (expected $EXPECTED_PLATFORM)" >&2
  exit 2
}

echo "converter-ffi iOS verification passed: $ARTIFACT"
