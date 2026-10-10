# Coding and review standards

Apply these standards to the requested scope. Explicit current user instructions
take precedence over older delivery documents, including their CI/PR gates.

## Implementation and tests

Keep conversion behavior in the shared Rust core and expose it through the
client's embedded adapter. Preserve EPUB TOC hierarchy, stable chapter identity,
artifact persistence, cancellation, and streaming playback at those seams.
Verify Rust Apple artifacts for architecture, platform, and ABI before embedding;
reject unsigned device bundles before calling devicectl.

Keep code, comments, logs, and technical documentation in English. Preserve
intentional localized strings, language-detection fixtures, and matching regexes.
Use existing module boundaries and remove obsolete paths when replacing them;
check source, tests, and manifests before deleting a referenced file.

Tests belong to the runtime they exercise:

- Native Swift: XCTest in ios/EpubToMp3/EpubToMp3Tests or EpubToMp3UITests.
- Rust: unit/integration tests in the owning crate.
- Tooling scripts: executable host tests for argument, process, and report behavior.
- Legacy Python and web: their own suites, only for those compatibility surfaces.

A host test may validate tooling around a native run; parsing Swift source cannot
prove native behavior. Use XCTest for native UI automation, never osascript or
ad hoc accessibility scripting. Select focused checks from actual mise task
definitions. Add regression coverage at the failing seam; documentation-only
changes need link/content and diff checks, not a runtime build.

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

Prefer physical iOS devices on the local 8 GiB Intel Mac. Build or run only when
authorized; check device readiness before building. Stop the previous app before
another native conversion run. Serialize builds, tests, and conversions through
the existing scripts/heavy_job_guard.py task integration; do not bypass its lock
or stack heavy jobs to maximize CPU/RAM use.

On resume, read the saved state and report, then check the recorded live PID once.
Continue from that evidence. Repeat a state query only after changed evidence
(new log/report data, process exit, user input, or an explicit status request);
unchanged state alone does not justify another polling loop or a duplicate run.

Reuse valid incremental artifacts when compatible and report cache reuse.
Retain at most one useful active build cache. Before cleanup, verify ownership,
tracked status, active processes, and whether the target is a release artifact.
Preserve inputs, models, .cache/, and output/ unless cleanup is authorized.
Report retained/removed temporary artifacts after a build/test cycle.

## Review and handoff

Review the complete owned diff against the goal and matching plan, including
scope, runtime boundaries, evidence, and resource cost. Stop after focused
verification passes unless new changes, failures, or uncertainty justify more.
Report changed paths, exact checks/results, skips, and unresolved limits.

Commit/push requires authorization; prior authorization within the task persists.
The user has standing commit/push authorization by default. Use Gitflow feature
branches from `master`; follow the PR, green-check, explicit auto-merge
authorization, and post-merge reconciliation rules in `AGENTS.md` and
`docs/agent-workflow.md`. CI/PR monitoring remains opt-in. Do not turn local
review into remote audits, issue triage, publication, or merge operations.
