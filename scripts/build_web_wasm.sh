#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The CLI and crate exchange a versioned schema and must match exactly.
locked_version="$(awk '/^name = "wasm-bindgen"$/ { found=1; next } found && /^version = / { gsub(/"/, "", $3); print $3; exit }' Cargo.lock)"
cli_version="$(mise exec -- wasm-bindgen --version)"
if [[ -z "$locked_version" || "$cli_version" != "wasm-bindgen $locked_version" ]]; then
  echo "wasm-bindgen schema mismatch: Cargo.lock=$locked_version; CLI=$cli_version. Install the matching pinned CLI before building." >&2
  exit 1
fi

output_dir="web/src/wasm"
mkdir -p "$output_dir"
rm -f "$output_dir"/converter_wasm.{js,d.ts} "$output_dir"/converter_wasm_bg.wasm "$output_dir"/converter_wasm_bg.wasm.d.ts

RUSTC="$(mise exec -- rustup which --toolchain stable rustc)" \
  mise exec -- rustup run stable cargo build --locked -p converter-wasm --target wasm32-unknown-unknown --release --jobs 1
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
