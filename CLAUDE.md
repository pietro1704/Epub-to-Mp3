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

For performance-sensitive choices, Pietro prefers the oldest compatible
technology and runtime on the target. Verify speed with a representative
profile; age alone is not performance evidence.

Inspect branch, status, applicable instructions, and relevant diff before editing.
Preserve unrelated changes and delegated file ownership. Always deliver the
smallest complete, atomic behavior change with its relevant regression test.
Reuse valid build artifacts and run only the checks needed to prove that change;
commit/push verified slices before expanding scope. Keep planning, delegation,
and documentation proportional to the task.
For substantial features when Pietro requests feature delivery, use Gitflow:
create a `feature/*` branch from current `master`, keep modules
cohesive and small, and apply SOLID at real ownership boundaries. Optimize the
measured hot path rather than splitting files to meet an arbitrary line count.
For a task that explicitly authorizes a PR and merge, open a PR targeting
`master`. Merge only after required checks are green. Enable auto-merge only
with explicit user authorization and after that green-check gate is satisfied.
CI/PR monitoring remains opt-in; report pending checks without polling unless
requested. PR authorization alone does not authorize merge. Follow
`docs/agent-workflow.md` for post-merge reconciliation.
For native Apple player/reader regressions, follow the exact Simulator procedure
in `docs/agent-workflow.md`.
Track every concrete user request/correction in `TODO_APP.md` before implementation;
keep stable task IDs, status, acceptance, platform checks and verification evidence.
Tick completion only after the affected app behavior is verified and delivered.
All development and verification happen on this Mac; do not route work to Arch.
Keep `TODO_APP.md` and `handoff.md` limited to task-specific acceptance and actual
verification evidence.
Use actual task definitions in `mise.toml`; run project tasks through `mise run`
and managed tools through `mise exec`.
Choose the smallest verification that proves acceptance; inspect the final diff.
Local Python execution and Ruff checks are deferred to CI. Use native Apple
tests for native verification. Persist explicit user corrections in the relevant
repository instructions and apply them on subsequent runs.
Native app builds and iOS Simulator actions for this verification are authorized by
the user's standing instruction. Other device/service actions still require task
authorization. Serialize native work with the existing guard.
Prefer `xcodes` with installed `aria2` for Apple downloads; use
`--experimental-unxip` for Xcode `.xip` extraction, not runtime `.dmg` imports.
Preserve useful partial downloads; keep extraction/build/Simulator work serialized.
Keep tests beside their runtime and report executed checks, skipped checks, and limits.
A source-contract check cannot prove native behavior or performance.
For device benchmarks, follow [the benchmark guide](docs/device-benchmark.md);
match the requested book/range literally and limit each book to two chapters unless
`--whole-book` is explicit. Resume from persisted state/report and check the live PID once.

Use existing `master`; substantial requested features use `feature/*` from
current `master` as described above.
Verified changes are committed and pushed by default;
the user has standing authorization unless explicitly revoked for a task.
Current user preference: no CI or PR monitoring. Do not infer permission to merge,
publish, close issues, or expand verification into repository-wide remote audits.
Completion means the authorized scope is implemented and its verification is reported;
a plan, skipped test, or displayed 100% alone does not establish success.
