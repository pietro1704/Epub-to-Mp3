# Delivery and migration guardrails

Objective

Keep Rust migration checks reproducible and make destructive branch cleanup
reviewable before it changes the remote repository.

Scope

- Browser Rust/WASM generation and artifact checks.
- Rust production packaging checks.
- Remote branch cleanup preview and explicit deletion.

Prerequisites

- Run commands from the repository root.
- `mise` must be installed and configured.
- SSH or another authenticated Git remote is required only for `--apply` cleanup.

Procedure

1. Run `mise run web:wasm-build`.
2. Run `mise run migration:build-and-gate`.
3. Run `mise run test:web`.
4. Preview branch cleanup:
   `bash scripts/cleanup_remote_branches.sh --remote origin`.
5. Review every `DELETE` line.
6. Apply only the reviewed set:
   `bash scripts/cleanup_remote_branches.sh --remote origin --apply`.
7. Keep Dependabot branches unless their deletion is separately authorized:
   `--delete-dependabot` is required.

Verification

- WASM artifacts exist and are non-empty.
- The embedded web converter references the generated Rust/WASM adapter.
- CLI and server release artifacts exist.
- `migration:gate` returns `RESULT PASS`.
- `git ls-remote --heads origin` matches the reviewed branch set.

Rollback

Remote branch deletion is not reversible by this script. Recover a deleted
branch from a local ref, an archive tag, or a known commit and push it again.
Create an archive tag before cleanup when branch history may still matter.

Known failures

- `migration:gate` requires release artifacts; use `migration:build-and-gate`
  in a clean checkout.
- The gate proves packaging and boundary wiring, not complete audio conversion
  on every product surface. Surface-level runtime smoke tests remain required
  until the Rust migration is functionally complete.
