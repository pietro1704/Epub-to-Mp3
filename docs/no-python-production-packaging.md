# Rust production packaging guard

Production conversion belongs in the Rust workspace. Apple clients embed
`converter-ffi`; CLI, browser/WASM and Flutter use their Rust adapters. Legacy
`python_app/`, `hf_app.py`, Python bridges and retained assets are compatibility/
migration material. Their presence does not select the production runtime and
is not permission to delete them.

`mise run guard:no-python-production` runs
`scripts/guard_no_python_production.sh`. The current script scans **only** tracked
`Dockerfile` and `.dockerignore` for forbidden Python packaging references. It
rejects the legacy override. It does not audit release workflows, Apple/Flutter
bundles, all mise tasks or the contents of built artifacts.

Before removing retained Python paths, identify their actual callers, migration
oracles, fixtures, workflows and packaging inputs. Verify replacement behavior at
each affected runtime, including errors/cancellation/identity; inspect actual
release artifacts for unwanted runtime files. The container guard alone cannot
prove client migration or packaging success. Do not replace embedded adapters
with a mandatory HTTP server to satisfy a historical migration checklist.

Read [runtime navigation](agents/runtime-navigation.md) and
[execution policy](agents/execution-policy.md) before builds or execution.
Python/Ruff execution remains deferred to CI; model installation and publication
retain their own authorization boundaries.
