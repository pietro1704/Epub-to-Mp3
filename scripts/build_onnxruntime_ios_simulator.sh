#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/target/onnxruntime-ios15-src"
build_dir="$source_dir/build/iOS/Release"
profile="Release-iphonesimulator"
runtime="$build_dir/$profile/libonnxruntime.1.24.2.dylib"
protobuf="$build_dir/_deps/protobuf-build/$profile/libprotobuf.a"

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$root/target"
  git clone --depth 1 --branch v1.24.2 https://github.com/microsoft/onnxruntime.git "$source_dir"
fi

if [[ ! -f "$runtime" || ! -f "$protobuf" ]]; then
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-16.4.0.app/Contents/Developer}" \
    mise exec -- bash "$source_dir/build.sh" \
      --config Release \
      --use_xcode \
      --ios \
      --apple_sysroot iphonesimulator \
      --osx_arch x86_64 \
      --apple_deploy_target 15.0 \
      --build_shared_lib \
      --parallel \
      --skip_tests \
      --skip_submodule_sync \
      --compile_no_warning_as_error \
      --cmake_extra_defines \
      onnxruntime_USE_FULL_PROTOBUF=ON \
      onnxruntime_BUILD_UNIT_TESTS=OFF >&2
fi

for library in \
  libonnxruntime_common.a libonnxruntime_flatbuffers.a libonnxruntime_framework.a \
  libonnxruntime_graph.a libonnxruntime_lora.a libonnxruntime_mlas.a \
  libonnxruntime_optimizer.a libonnxruntime_providers.a libonnxruntime_session.a \
  libonnxruntime_util.a; do
  [[ -f "$build_dir/$profile/$library" ]] || {
    echo "ONNX Runtime build is missing $library" >&2
    exit 1
  }
done
[[ -f "$build_dir/_deps/onnx-build/$profile/libonnx.a" ]]
[[ -f "$build_dir/_deps/onnx-build/$profile/libonnx_proto.a" ]]
[[ -f "$protobuf" ]]

printf '%s\n' "$build_dir"
