# Phase 3: Xcode and mise speed and build quality

Status: source-grounded execution plan; no build measurements have been made.
Return to the [audit overview](../2026-11-03-complete-code-audit.md).

## Outcome and scope

Improve measured developer turnaround without weakening runtime correctness,
diagnostics, reproducibility, signing, resource guards or supported platforms.
This is the final part of the Swift stage, before shared Rust changes.

The source of truth is [project.yml](../../../ios/EpubToMp3/project.yml),
[root mise.toml](../../../mise.toml),
[nested mise.toml](../../../ios/EpubToMp3/mise.toml),
[Package.swift](../../../ios/EpubToMp3/Package.swift) and their build scripts.
Read [execution policy](../../agents/execution-policy.md) and
[macOS validation](../../agents/macos-validation.md) before invoking tasks.

## Observations, not performance conclusions

| Inspected source | Observed setting | Question to investigate |
| --- | --- | --- |
| XcodeGen | Version 2.46.0; project format compatible with Xcode 15 | Which consumers still need that project format? |
| Toolchain routing | `.xcode-version` says 15.4; routing selects 16.4 or device-specific 26.3 | Are external tools reading the older marker, or is it informational? |
| Debug | Incremental, `-Onone`, active architecture, index store disabled | Which work invalidates caches or still dominates iteration? |
| App Release | Whole-module, `-O`, ThinLTO, dSYM | What are actual compile/link/runtime/size tradeoffs? |
| Script sandbox | Base YES; app target overrides NO | What real script inputs/outputs and permissions are needed? |
| Quality flags | Warnings as errors, concurrency `minimal`, strict memory safety NO | What diagnostics can be adopted compatibly in a focused slice? |
| Packaging | Four post-build scripts disable dependency analysis | Which costs are measurable and safely avoidable? |
| mise | Fixed and moving versions; nested Codex repeats the root entry | Which tools are build inputs, platform-specific, or development-only? |

The Release preview comment claims inherited ON while base `ENABLE_PREVIEWS` is
NO. This is a documentation inconsistency to reconcile. Do not infer the effective
Release optimization from base `-Onone`: the app target explicitly overrides it.
Commented percentage improvements are hypotheses until supported by comparable
measurements. Do not turn these observations into blanket flag changes.

## Step 1: map tasks and side effects

1. List each supported entrypoint and its task dependencies: project generation,
   app build, package verification, native tests, device install/run, model
   installation and compatibility builds. Read the scripts, not only descriptions.
2. Mark tasks as read-only inspection, filesystem write, dependency compilation,
   final-app compilation, device/GUI action or network/download. Record implicit
   actions and failure behavior. Some tasks cross several categories.
3. Trace `mac:build` to `converter-ffi:build`; compare with the independent
   `mac:validate` inspect/package/build/gui modes. Inspect the missing-library
   branch in `scripts/bundle_converter_ffi_ios.sh` before any app build.
4. Inspect `xcode:generate`, which also opens the generated project. Do not treat
   it as a read-only metadata command. Prefer the smallest existing route that
   proves the intended change.
5. Audit generic `install` and `clean` tasks separately. The current generic
   install reaches broad Python/web/Piper setup; generic clean can remove
   application output/state. Neither is audit preparation.

Deliverable: a task graph with actual command, dependencies, side effects,
platform owner, artifact requirements and focused verification entrypoint.

## Step 2: capture effective settings and artifact identity

1. Create a matrix of app, widget, share extension and test targets by supported
   SDK and Debug/Release configuration. Record deployment target, language mode,
   architectures, optimization, concurrency, diagnostics, signing and resources.
2. Compare declared base, project configuration, target override and command-line
   values. Inspect existing generated metadata and receipts first. If querying
   effective Xcode settings, prevent implicit dependency resolution/downloads and
   retain the exact invocation; this is not permission to launch Simulator.
3. Reconcile Xcode compatibility format, compiler version, SDK and runtime as
   separate identities. Preserve Xcode 26.3 routing for iPhone 16e and required
   legacy toolchains through per-command selection, not global `xcode-select`.
4. Inventory existing compatible DerivedData and native prebuilts, including
   receipts across linked worktrees. Match source, lockfile, toolchain, target,
   flags, ABI and payload hashes before reuse.
5. Ask about verified prebuilts before any dependency/runtime/library/tool
   compilation on Mac. If no compatible artifact is available and approval is
   absent, record the check as blocked rather than triggering a fallback build.

Do not publish device IDs, signing state, environment dumps or private receipt
paths as generic build documentation. Keep reproducibility facts appropriately
redacted and preserve all originals.

## Step 3: establish a controlled baseline

1. Select one authorized app target and one valid existing cache. Inspect
   `build:storage`; remove only superseded reproducible build outputs through
   `clean:build` when necessary and permitted. Respect the 20 GiB free floor,
   12 GiB cache budget and single compiler job.
2. Record hardware/OS, source SHA and dirty state, compiler/SDK, configuration,
   architectures, native artifact receipt and cache state. Wait for the existing
   native lease and stop only work started by this audit when needed; preserve
   unrelated active processes. Never raise parallelism to improve a score.
3. Measure no-change build, one Swift implementation change, one resource change,
   and a representative Release build, only as authorized and necessary. Use
   disposable/reversible probe changes; keep them out of the delivered diff.
4. Retain `-showBuildTimingSummary`, phase durations, total wallclock, disk growth,
   rebuild counts and product size. Identify generation, compile, link, copy,
   signing and dependency work separately. Report setup and skipped work.
5. Repeat comparable samples enough to expose variance before claiming a gain.
   Do not erase useful caches to manufacture a cold comparison. A new cold-build
   campaign or app benchmark needs its explicit bounded execution scope.

The baseline produces measured bottlenecks and ranked hypotheses, not a universal
fast-build preset. Runtime latency/audio quality require their own evidence.

## Step 4: investigate one bottleneck at a time

| Candidate | Identification method | Proof required for a change |
| --- | --- | --- |
| Always-running scripts | Time FFI/eSpeak/ONNX copy and verification phases | Inputs/outputs invalidate correctly; changed/missing/stale artifacts rejected |
| Unnecessary dependency builds | Trace app task graph and package receipts | Unchanged Rust reused; changed Rust/ABI cannot reuse stale bytes |
| Cache fragmentation | Compare routed DerivedData and config/SDK identities | Correct cache reused without cross-target contamination |
| Compilation/link settings | Compare effective values and matched timings | Preserved debugging and behavior; measured build/runtime/size results |
| Asset generation | Inspect symbol generation, localization and membership | Required resources still bundled; no missing symbols or runtime strings |
| Broad tool setup | Trace mise inheritance and install branches | Each platform obtains required tools without installing unrelated SDKs |

For scripts, cover success, missing input, stale identity, failed signing,
interruption and repeated execution. Avoid replacing mandatory verification with
an mtime-only shortcut. Use real platform tools on preserved binary copies for
packaging/signature claims; mocks alone are insufficient.

## Step 5: review quality and compatibility deliberately

1. Inspect warnings and exceptions by target. Separate genuine production
   diagnostics from generated/vendor noise; do not silence warnings globally.
2. Evaluate stricter concurrency or memory diagnostics against each supported
   compiler. First record affected seams and migration effort; seek confirmation
   for consequential language/toolchain/compatibility changes.
3. Evaluate supported sanitizers in focused debug/test runs. Their instrumentation
   is not a release optimization and cannot replace real app acceptance.
4. Verify Debug diagnostics and Release symbols, testability, safety checks,
   entitlements, architecture, linked libraries and signing. Compare app and
   extension overrides; do not apply a single flag mechanically to every target.
5. Reconcile comments and documented defaults with effective values. Change only
   settings justified by a reproduced problem or measured tradeoff.

## Step 6: make mise reproducible by platform

1. Trace root/nested configuration and relevant installed tool resolution without
   dumping credentials or updating global configuration. If personal Codex/Hermes
   configuration enters scope, follow the user's AIConfig routing instructions
   and revalidate its active files before changes.
2. Separate app build inputs from development conveniences. Review moving
   `stable`, `lts` and `latest` selections against reproducibility requirements;
   propose pins only where justified, with an update strategy.
3. Verify Flutter/Dart, Rust/WASM CLI schema and native producer compatibility
   against lockfiles and CI. Inspect dependency backend compilation implications
   before selecting or installing a new tool version.
4. Preserve Android SDK ownership on Arch and the existing Linux-only SDK
   restriction. Missing tools must fail clearly, without bootstrapping unrelated
   Android tools or changing the global Xcode selection.
5. Keep existing task names where possible. Document the minimal inspect,
   package, build and test route, including side effects and artifact reuse.

## Step 7: verification and exit criteria

Read the current definitions before selecting these existing checks:

- `host:workflow:test`: task wiring, Xcode path routing and native entrypoints.
- `mac:validate:test`: mode selection, reuse identity and error handling.
- `converter-ffi:ios-packaging:test`: iOS packaging orchestration and boundaries.
- `build:storage:test` and `native:build:preflight:test`: affected guard behavior.
- `mac:validate -- inspect|package|build|gui`: explicitly selected real artifact
  checks; no implicit escalation between modes.
- Native XCTest and visible app journey for affected runtime behavior;
  `apple:foundation:test` is a compiled subset, and its FFI variant compiles Rust.

For each delivered change, review the exact settings/documentation diff and run
checks proportional to its impact. Performance claims require comparable
before/after measurements; tooling changes require executable regressions;
packaging/runtime changes require evidence at those affected seams. A comment
correction needs content/link checks, not a benchmark or app journey. For optimized
artifact reuse, confirm rejection of wrong platform, ABI, stale source and missing
assets. Keep required Simulator acceptance blocked while quarantined.

Finish with a documented settings/task matrix, measured accepted improvements,
unchanged safety limits, explicit rejected hypotheses and unresolved checks.
The first implementation slice should address the smallest proven bottleneck or
documentation inconsistency; a global toolchain/flag overhaul is not the default.
