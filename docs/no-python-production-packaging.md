# Rust production packaging guard

Phase 6.2 makes the intended production boundary explicit: release artifacts
must be built from the Rust workspace and must not bundle the legacy Python
runtime or bridge. `python_app/`, `hf_app.py`, and the Python bridge scripts are
still retained as migration references until all clients have Rust adapters.
They are not safe to delete yet.

## Guard

Run `mise run guard:no-python-production` from the repository root. The guard
fails if Docker, mise, release workflows, or packaging manifests reintroduce
Python runtime/bootstrap references. It deliberately does not scan source,
tests, or historical documentation, so the remaining migration surface stays
visible without blocking unrelated development.

## Removal prerequisites

The following prerequisites must be satisfied before deleting the retained
Python paths:

- Keep the Rust server as the canonical hosted image/entrypoint; retain the HF
  Python adapter only as a migration oracle until the final differential gate.
- Keep the macOS Rust server binary as the production sidecar; remove
  Python.xcframework/vendor bootstrap phases from the Apple target.
- Replace Android Chaquopy and desktop Flutter Python asset bootstraps with the
  Rust service integration.
- Update client launch, API, and release workflows to consume the Rust binary.
- Remove Python-only CI jobs and dependency installation after equivalent Rust
  and client coverage exists.
- Re-run the guard and inspect the release artifacts for Python runtime files.

Until all prerequisites are complete, do not delete `python_app/`,
`hf_app.py`, `desktop.spec`, or the platform bootstrap scripts wholesale.
