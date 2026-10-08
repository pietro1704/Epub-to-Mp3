# Project instructions

Reply in concise Brazilian Portuguese. Keep code, comments, logs, and technical
documentation in English; preserve literal identifiers, locale strings, and fixtures.
Current explicit user instructions override older workflow defaults.

## Runtime

Apple clients use native Swift (UIKit/AppKit) and the embedded Rust
`converter-core`/`converter-ffi` pipeline for both macOS and iOS.
Rust owns conversion, provider/model selection, progress, cancellation, and artifacts.
Online/offline operation is a provider configuration, not a platform converter.
Product CLI, web, and Flutter integrations use Rust binaries, WASM, or bindings.
Python/FastAPI remains legacy compatibility material, not an Apple sidecar or
a product runtime dependency. Shared conversion features belong in Rust first.

## Navigation

Read [CODING_STANDARDS.md](CODING_STANDARDS.md) during review.
For conversion, FFI, client routing, or runtime tests, read
[the runtime map](docs/agents/runtime-navigation.md).
For multi-file features, regressions, integration, or workflow changes, read
[the delivery workflow](docs/agent-workflow.md), subject to current user scope.
For native reader changes, read `ios/EpubToMp3/AGENTS.md`, `CONTEXT.md`,
the relevant `docs/adr/`, and use the native-reader-regression skill.
For legacy Python CLI/server changes only, read
[legacy gotchas](docs/legacy-agent-reference.md).
For domain documentation use `docs/agents/domain.md`; for authorized issue work
use `docs/agents/issue-tracker.md`.

## Execution and delivery

Inspect branch, status, applicable instructions, and relevant diff before editing.
Preserve unrelated changes and delegated file ownership; implement a focused slice.
Use actual task definitions in `mise.toml`; run project tasks through `mise run`
and managed tools through `mise exec`.
Choose the smallest verification that proves acceptance; inspect the final diff.
Local Python execution and Ruff checks are deferred to CI. Use native Apple
tests for native verification. Persist explicit user corrections in the relevant
repository instructions and apply them on subsequent runs.
Builds and device/service actions require task authorization. Prefer physical iOS
devices on this low-memory Intel Mac; serialize heavy work with the existing guard.
Keep tests beside their runtime and report executed checks, skipped checks, and limits.
A source-contract check cannot prove native behavior or performance.
For device benchmarks, follow [the benchmark guide](docs/device-benchmark.md);
match the requested book/range literally and limit each book to two chapters unless
`--whole-book` is explicit. Resume from persisted state/report and check the live PID once.

Use Gitflow: implement on a feature/fix branch based on the integration branch,
never directly on master. Verified changes are committed and pushed by default;
the user has standing authorization unless explicitly revoked for a task.
Current user preference: no CI or PR monitoring. Do not infer permission to merge,
publish, close issues, or expand verification into repository-wide remote audits.
Completion means the authorized scope is implemented and its verification is reported;
a plan, skipped test, or displayed 100% alone does not establish success.
