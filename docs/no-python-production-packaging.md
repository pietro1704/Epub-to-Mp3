# Rust production packaging guard

Production conversion belongs in the Rust workspace. Apple clients embed
`converter-ffi`; CLI, browser/WASM and Flutter use their Rust adapters. The
legacy Python application (`python_app/`, `hf_app.py` and the client Python
bridges) was removed; the guard keeps it from returning to production packaging.

`mise run guard:no-python-production` runs
`scripts/guard_no_python_production.sh`. The current script scans **only** tracked
`Dockerfile` and `.dockerignore` for forbidden Python packaging references. It
rejects the legacy override. It does not audit release workflows, Apple/Flutter
bundles, all mise tasks or the contents of built artifacts.

Inspect actual release artifacts for unwanted runtime files; the container guard
alone cannot prove client packaging success. Do not replace embedded adapters
with a mandatory HTTP server to satisfy a historical migration checklist.

Read [runtime navigation](agents/runtime-navigation.md) and
[execution policy](agents/execution-policy.md) before builds or execution.
Host scripts are Ruby; the repository no longer ships Python tooling. Model
installation and publication retain their own authorization boundaries.
