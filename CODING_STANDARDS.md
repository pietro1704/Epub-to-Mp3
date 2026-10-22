# Coding and review standards

Apply these standards to the requested scope. Explicit current user instructions
take precedence over older delivery documents, including their CI/PR gates.

## Agent-readable source

Keep project-owned source and test files below 500 physical lines. Split by
responsibility behind the existing module interface. Keep explanatory comments
with the code they explain; do not delete them or compress statements to meet the
limit. Inventory existing oversized files and bring each refactored responsibility
below the limit before closing that refactor. Record generated and unmodified
third-party sources as exclusions with their ownership.

Use specific, searchable domain names for owned declarations. Replace generic
names such as `data`, `handler` and `Manager` with the role they represent.
Preserve external API requirements, FFI symbols, serialized keys and localized
strings; migrate owned names together with callers and runtime tests.

## Implementation and tests

Keep conversion behavior in the shared Rust core and expose it through the
client's embedded adapter. Preserve EPUB TOC hierarchy, stable chapter identity,
artifact persistence, cancellation, and streaming playback at those seams.
Verify Rust Apple artifacts for architecture, platform, and ABI before embedding;
reject unsigned device bundles before calling devicectl.

Keep code, comments, logs, and technical documentation in English. Preserve
intentional localized strings, language-detection fixtures, and matching regexes.
For native Apple appearance, use platform semantic colors and native materials.
Light and dark modes share the same material/transparency configuration; let the
OS adapt its rendering. Warm/custom reader palettes remain explicit choices.
Verify actual rendered colors and materials rather than a separate sample palette.
Use existing module boundaries and remove obsolete paths when replacing them;
check source, tests, and manifests before deleting a referenced file.

Tests belong to the runtime they exercise:

- Native Swift: XCTest in ios/EpubToMp3/EpubToMp3Tests or EpubToMp3UITests.
- Rust: unit/integration tests in the owning crate.
- Tooling scripts: executable host tests for argument, process, and report behavior.
- Web/TypeScript: the web suite for active Rust/WASM client behavior.
- Flutter/Dart: Flutter tests for bindings, state and UI behavior.
- Legacy Python: its own compatibility suite; Python/Ruff execute in CI.

A host test may validate tooling around a native run; parsing Swift source cannot
prove native behavior. Use XCTest for native UI automation, never osascript or
ad hoc accessibility scripting. Select focused checks from actual mise task
definitions and expose the relevant suite through one command per runtime. Add a
focused task only when an existing command cannot exercise the requested seam.
Every bug fix adds a regression that reproduces the observed failure. Demonstrate
failure before the fix when feasible; record why it was not possible otherwise.
Cover each changed behavior at its failing seam, including success and relevant
failure, cancellation or identity cases. Coverage percentages alone do not prove
acceptance. Documentation-only changes need link/content and diff checks, not a
runtime build.

## Benchmark review

Compare the selected input path and chapter range with the user's literal request.
Keep indices zero-based and inclusive; 8 9 selects exactly two chapters.
Allow at most two selected chapters per book unless --whole-book is explicit.
Reject broader scope before device actions; do not silently substitute books,
renumber chapters, or expand ranges to obtain a convenient result.

Use the workflow in [docs/device-benchmark.md](docs/device-benchmark.md).
Review the persisted report against the selected chapters, terminal success,
job/artifact records, and playable output. A displayed 100% may precede final
persistence and playback handoff.

Report task wallclock separately from build, device readiness/transfer, wait,
synthesis, and verification. Describe interval overlap instead of adding
overlapping timings. Identify cache reuse, skipped chapters, and skipped tests;
cached audio or skipped tests are not proof of synthesis performance.
Performance comparisons need comparable book/range, provider/model, cache state,
and before/after measurements. A passing source-contract test supplies no
native performance evidence.

## Environment and resumption

Use the exact native destinations required by the task and native reader contract.
Apply [execution policy](docs/agents/execution-policy.md), including Simulator
quarantine and guarded single-job Mac compilation. A physical device does not
replace required SE1/iOS 15.5 verification. A reviewer must preserve blocked
acceptance rather than accepting an alternate runtime as equivalent.

On resume, read the saved state and report, then check the recorded live PID once.
Continue from that evidence. Repeat a state query only after changed evidence
(new log/report data, process exit, user input, or an explicit status request);
unchanged state alone does not justify another polling loop or a duplicate run.

Reuse valid incremental artifacts when compatible and report cache reuse.
Respect the shared build-storage budget. Before cleanup, verify ownership,
tracked status, active processes, and whether the target is a release artifact.
Preserve inputs, models, .cache/, and output/ unless cleanup is authorized.
Report retained/removed temporary artifacts after a build/test cycle.

## Review and handoff

After each change, record expected outcome, command/source identity, observed
result and PASS/FAIL/BLOCKED evidence. Continue dependent work only after that
change's required acceptance passes. Report policy-blocked checks explicitly;
another runtime cannot stand in for the required target.

Review the complete owned diff against the goal and matching plan, including
scope, runtime boundaries, evidence, and resource cost. The reviewer owns this
enforcement; implementation needs the affected seam and acceptance, not another
copy of every review rule. Require a concrete unresolved failure or acceptance
gap before expanding a focused fix into broader suites, tooling work or redesign.
Stop after focused verification passes unless new evidence justifies more.
Report changed paths, exact checks/results, skips, and unresolved limits.

For signing, linking and packaging changes, require an executable check using
the actual platform tool on a preserved copy of a representative real binary.
Mock success alone cannot establish Mach-O loadability, signature validity or
app launch. Distinguish packaging, build, test execution and visible-app evidence;
record each phase's duration when claiming a faster feedback loop. Confirm cache
identity before reuse and explain fresh dependency compilation before it begins.

Identity-sensitive temporary fixtures use canonical paths (`File.realpath`);
macOS `/var` and `/private/var` aliases must not produce false regression failures.

For host workflow tooling, review the executable boundaries: a failed or
cancelled command must prevent later work and retain its real status; index
transactions must prove scope and local-byte preservation; instruction patches
must be idempotent and preserve aliases. Require concurrency and identity
failure coverage at those seams. Use `mise run host:workflow:test` and the
controls documented in `docs/agent-workflow.md`; host fixtures do not certify
native apps, Xcode descriptor propagation or kernel/driver stability.

Apply commit, PR, merge and monitoring boundaries from
[execution policy](docs/agents/execution-policy.md). Reviewers verify the minimal
exact-head PR gate and server enforcement before accepting an auto-merge claim;
optional post-merge work must not silently become a pre-merge requirement.
A successful API request or `--auto` invocation is not evidence that checks
blocked merging. Preserve explicit publication authorization boundaries.
