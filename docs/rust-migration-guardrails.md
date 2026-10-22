# Delivery and migration guardrails

Rust migration checks establish packaging and client wiring at their affected
runtime. Select the relevant checks under [execution policy](agents/execution-policy.md):
Apple builds run on Mac, Flutter/Android builds belong on Arch, and Python/Ruff
execute in CI. Use guarded compiler tasks and preserve compatible caches.

## Migration verification

Run the commands relevant to the changed surface from the repository root with
`mise` installed and configured:

- `mise run web:wasm-build` generates browser Rust/WASM artifacts.
- `mise run migration:build-and-gate` builds CLI/server release artifacts and
  checks migration boundaries. `migration:gate` alone requires existing artifacts.
- `mise run test:web` exercises the Web client.

Inspect the selected task before execution. A focused change does not require
all three commands. Confirm generated artifacts are non-empty, the embedded
browser client references its Rust/WASM adapter, and the relevant gate reports
`RESULT PASS`. These checks establish packaging and boundary wiring; actual
conversion and playback require evidence at the affected product surface.

## Separately scoped branch maintenance

Branch cleanup requires its own authorization and reviewed deletion set. An
SSH or other authenticated remote is needed only for applying remote changes.

1. Preview with `bash scripts/cleanup_remote_branches.sh --remote origin`.
2. Inspect every `DELETE` line and preserve unique work and evidence.
3. After authorization for that exact set, apply with
   `bash scripts/cleanup_remote_branches.sh --remote origin --apply`.
4. Preserve Dependabot branches unless deletion is separately authorized;
   `--delete-dependabot` is required to include them.
5. Verify `git ls-remote --heads origin` against the reviewed final set.

Remote deletion is not reversible by this script. Retain a local ref, an archive
tag or the exact commit before removing history that may still matter. Recover
by pushing the preserved ref or commit. Keep this maintenance separate from
migration acceptance.
