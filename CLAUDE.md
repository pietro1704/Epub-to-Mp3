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

Current TTS policy: Piper `pt_BR-faber-medium` is the default primary provider.
The user may select a primary and optional secondary provider; online Edge
fallback requires explicit consent and is disabled by default. Manual conversion
may inherit preferences or capture a strict per-job selection. Retry the primary
on each segment and stop persistent failures instead of switching a whole book.
Prioritize first playable audio on weak phones. Install models only through an
explicit user action; never download implicitly or require a paid provider.

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

Close the app, shut down its Simulator and quit Simulator.app whenever active verification stops; stop the native Mac app whenever idle. Retain screenshots/reports and confirm shutdown.

For autonomous whole-app verification, read the campaign plan in
`docs/plans/2026-10-15-ios-whole-app-verification.md`. Review plans with
specialists before executing. Parallelize independent inspection and review;
serialize native compilation and Simulator work through the existing hooks and
native lease. Exercise each corrected behavior in the real Simulator app and
add meaningful unit, integration or UI regression coverage before delivery.
When the user requests unattended work, continue independent tasks around
blockers and report the remaining user-dependent items at the end.
The 2026-10-15 campaign explicitly authorizes one branch/PR per feature or bug
and merge to `master` after green required checks, including the focused check
monitoring needed for those PRs. This is task-specific merge authorization.
This campaign also includes actual native macOS verification, then corresponding
Flutter work on separate branches with Samsung/Android and Arch Linux checks.
Close iOS Simulator before macOS verification and stop the Mac app whenever idle.

For performance-sensitive choices, Pietro prefers the oldest compatible
technology and runtime on the target. Verify speed with a representative
profile; age alone is not performance evidence.

Inspect branch, status, applicable instructions, and relevant diff before editing.
Preserve unrelated changes and delegated file ownership. Always deliver the
smallest complete, atomic behavior change with its relevant regression test.
Preserve verified working app behavior. Limit edits to what the current request
requires; keep unrelated working flows unchanged and avoid opportunistic
refactoring, redesign, or cleanup. Revisit previously resolved areas only when
concrete evidence shows the current task requires it, with a minimal change and
verification of the affected regression.
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
Native Apple development and verification happen on this Mac. Authorized
Flutter Linux and Android/Samsung implementation and verification run on Arch.
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
authorization. Serialize native work with the existing guard. For authorized
verification, run the available tests, snapshots, UI automation, and Simulator
interactions yourself; do not hand test execution steps to the user.
For audible checks, show the tested app/Simulator GUI and identify deliberate
non-Edge fixture audio before playback; distinguish it from normal app narration.
Before switching native targets, stop the active app and shut down its Simulator;
verify the previous target has exited before starting another. Never leave the
macOS app and an iOS Simulator app running together. Close the app, shut down its Simulator and quit Simulator.app whenever active verification stops, including the end of a campaign. Confirm shutdown and retain screenshots/reports.
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
