#!/usr/bin/env bash
set -euo pipefail

ROOT="${MISE_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ARTIFACT="${CONVERTER_FFI_IOS_ARTIFACT:-$ROOT/target/aarch64-apple-ios/release/libconverter_ffi.dylib}"
SYMBOL="converter_session_convert_json"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "converter-ffi iOS verification error: missing $ARTIFACT" >&2
  exit 2
fi

FILE_INFO=$(file "$ARTIFACT")
echo "$FILE_INFO"
grep -q "Mach-O" <<<"$FILE_INFO" || { echo "converter-ffi iOS verification error: not a Mach-O library" >&2; exit 2; }
grep -q "arm64" <<<"$FILE_INFO" || { echo "converter-ffi iOS verification error: missing arm64 architecture" >&2; exit 2; }

if ! nm -gU "$ARTIFACT" | grep -q "_$SYMBOL$"; then
  echo "converter-ffi iOS verification error: missing exported symbol $SYMBOL" >&2
  exit 2
fi

otool -l "$ARTIFACT" | grep -A4 "LC_BUILD_VERSION" | grep -q "platform 2" || {
  echo "converter-ffi iOS verification error: library is not linked for iOS" >&2
  exit 2
}

echo "converter-ffi iOS verification passed: $ARTIFACT"
