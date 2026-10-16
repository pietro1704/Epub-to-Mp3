#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${PLATFORM_NAME:-}" in
  macosx)
    case "${ARCHS:-}" in
      x86_64|arm64) runtime_arch="$ARCHS" ;;
      *) echo "error: ONNX packaging requires one explicit architecture" >&2; exit 2 ;;
    esac
    ;;
  iphonesimulator)
    source="$root/target/onnxruntime-ios15-src/build/iOS/Release/Release-iphonesimulator/libonnxruntime.1.24.2.dylib"
    ;;
  *) exit 0 ;;
esac
artifact="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/libconverter_ffi.dylib"
if [[ "${PLATFORM_NAME:-}" == macosx ]]; then
  mise exec -- ruby - "$artifact" <<'RUBY_GUARD'
require 'rubygems/version'
load_commands = IO.popen(['xcrun', 'otool', '-l', ARGV.fetch(0)], &:read)
minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)/m, 1]
abort "Embedded converter-ffi exceeds macOS 12: #{minimum.inspect}" unless minimum && Gem::Version.new(minimum) <= Gem::Version.new('12.0')
RUBY_GUARD
fi

# Inspect successfully before distinguishing static and dynamic inference builds.
# A missing inspection tool must never silently omit a required runtime.
if ! linked_libraries="$(otool -L "$artifact")"; then
  echo "error: cannot inspect linked ONNX Runtime dependencies: $artifact" >&2
  exit 1
fi
linked_name="$(printf '%s\n' "$linked_libraries" | awk '/libonnxruntime/ { name=$1; sub(/^.*\//, "", name); print name; exit }')"
[[ -n "$linked_name" ]] || exit 0
if [[ "${PLATFORM_NAME:-}" == macosx ]]; then
  runtime_directory="$(ONNXRUNTIME_MACOS_ARCH="$runtime_arch" mise exec -- ruby "$root/scripts/prepare_onnxruntime_macos.rb")"
  source="$runtime_directory/libonnxruntime.dylib"
fi
[[ -f "$source" ]] || { echo "error: missing linked ONNX Runtime: $source" >&2; exit 1; }
destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/$linked_name"
cp "$source" "$destination"
install_name_tool -id "@rpath/$linked_name" "$destination"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination"
codesign --verify --strict "$destination"
