#!/usr/bin/env bash
set -u

# Report the final Rust migration gate without mutating the repository.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0
blockers=()

pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'BLOCKED %s\n' "$1"
  blockers+=("$1")
  failures=$((failures + 1))
}

printf 'Rust migration gate\n===================\n'

if [[ -f Cargo.toml ]]; then
  pass "Rust workspace manifest exists"
  workspace_members="$(sed -n '/^members = \[/,/^\]/p' Cargo.toml | sed -n 's/.*"\([^"]*\)".*/\1/p')"
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    if [[ -f "$member/Cargo.toml" ]]; then
      pass "Rust workspace member: $member"
    else
      fail "Missing Cargo manifest for workspace member: $member"
    fi
  done <<< "$workspace_members"
else
  fail "Missing Rust workspace manifest: Cargo.toml"
fi

for entrypoint in \
  crates/converter-cli/src/main.rs \
  crates/converter-server/src/main.rs; do
  if [[ -f "$entrypoint" ]]; then
    pass "Production Rust entrypoint exists: $entrypoint"
  else
    fail "Missing production Rust entrypoint: $entrypoint"
  fi
done

if [[ -x scripts/guard_no_python_production.sh ]]; then
  pass "No-Python production guard is executable"
else
  fail "No-Python production guard missing or not executable: scripts/guard_no_python_production.sh"
fi

for wasm_artifact in \
  web/src/wasm/converter_wasm.js \
  web/src/wasm/converter_wasm.d.ts \
  web/src/wasm/converter_wasm_bg.wasm; do
  if [[ -s "$wasm_artifact" ]]; then
    pass "Browser WASM artifact exists: $wasm_artifact"
  else
    fail "Missing browser WASM artifact: $wasm_artifact"
  fi
done
if [[ -f web/src/services/EmbeddedConverter.ts ]] && \
   grep -q 'wasm/converter_wasm' web/src/services/EmbeddedConverter.ts; then
  pass "Web embedded converter is wired to Rust WASM"
else
  fail "Web embedded converter is not wired to the generated Rust WASM module"
fi

artifact_found=0
for artifact in \
  dist/epub-to-mp3-server \
  target/release/converter-cli \
  target/release/converter-server; do
  if [[ -e "$artifact" ]]; then
    pass "Generated production artifact exists: $artifact"
    artifact_found=1
  fi
done
if (( artifact_found == 0 )); then
  fail "No generated Rust production artifact found (expected dist/ or target/release/)"
fi

if [[ -d target ]]; then
  pass "Rust build directory exists: target/"
else
  fail "Rust build artifacts have not been generated: target/"
fi

if [[ -d dist ]]; then
  pass "Packaging directory exists: dist/"
else
  fail "Packaging output directory is missing: dist/"
fi

if (( failures == 0 )); then
  printf '\nRESULT PASS\n'
  exit 0
fi

printf '\nRESULT BLOCKED (%d)\n' "$failures"
printf 'Remaining blockers:\n'
for blocker in "${blockers[@]}"; do
  printf -- '- %s\n' "$blocker"
done
exit 1
