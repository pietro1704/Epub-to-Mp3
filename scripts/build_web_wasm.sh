#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="web/src/wasm"
mkdir -p "$output_dir"
rm -f "$output_dir"/converter_wasm.{js,d.ts} "$output_dir"/converter_wasm_bg.wasm "$output_dir"/converter_wasm_bg.wasm.d.ts

mise exec -- cargo build -p converter-wasm --target wasm32-unknown-unknown --release
mise exec -- wasm-bindgen \
  target/wasm32-unknown-unknown/release/converter_wasm.wasm \
  --target web \
  --out-dir "$output_dir"

for artifact in \
  "$output_dir/converter_wasm.js" \
  "$output_dir/converter_wasm.d.ts" \
  "$output_dir/converter_wasm_bg.wasm"; do
  test -s "$artifact" || {
    echo "missing or empty WASM artifact: $artifact" >&2
    exit 1
  }
done

echo "generated browser WASM artifacts in $output_dir"
