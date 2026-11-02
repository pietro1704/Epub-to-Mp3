# Consolidation validation results

The latest reconciliation is [2026-11-02 delivery verification](#2026-11-02--delivery-verification).
Earlier dated blocks preserve the state observed then; resolved cache, lease,
worktree and PR blockers are historical. Current implementation/acceptance status
is in the [ordered TODO](../../RESUME_CONSOLIDATION.md).

## 2026-11-01 — inventory and storage preflight

- PASS: read branch/status/diffs for the eight EPUB worktrees; fetched origin and checked patch equivalence for narration and interrupted export recovery.
- PASS: checked ignored-file collisions before creating the integration branch from master; none found.
- BLOCKED: `mise run build:storage` reports 13,363,396,608 cache bytes, exceeding the 12 GiB guard. Free disk is approximately 75 GiB.
- EXECUTED: `mise run clean:build` exited 0 but removed no superseded Xcode cache; the storage guard remains blocked.
- NOT RUN: consolidated Rust/Swift runtime tests, app build, visible app acceptance.
- NOT DONE: silence compaction, remaining feature integration, worktree removal.

No historical test result is being presented as a test of the consolidated sources.

## 2026-11-01 — generated-speech regression

- RED: `cargo test --locked -p converter-core --lib speech_silence_tests --jobs 1` executed through `scripts/native_build_command.rb`. One pass, one expected failure: the original 3-second fixture decoded to 3.024 seconds, outside the expected 1.25–1.45 seconds. Evidence: `.reports/consolidation-20261101/silence-red.log`.
- GREEN: `cargo test --locked -p converter-core --lib --jobs 1` through the same guard: **315 passed, 0 failed, 1 ignored**, runtime 21.58 seconds. The ignored test is the manual chapter-cache timing benchmark. This includes cancellation, replacement, provider failure and persisted cache tests. Evidence: `core-green.log` in the same evidence directory.
- FINAL FOCUSED: after adding WAV/MP3 and processing-identity coverage, `cargo test --locked -p converter-core --lib speech_silence --jobs 1`: **6 passed, 0 failed**, runtime 0.53 seconds. Evidence: `silence-final.log`. Only extra tests and extraction of existing PCM tests into a separate module followed the full core run; a final rerun is pending.
- PASS: `mise run preflight`; local host workflow checks passed, with Python and broader CI checks explicitly deferred by the task. Evidence: `preflight.log`.
- PASS: storage guard after removal of obsolete compiler intermediates under the shared lock. Old exported FFI binaries were preserved; models, books, output and evidence were not removed. `cargo clean` refused a missing cache marker, so its invocation is not recorded as a successful cleanup. The narrowly identified release build/deps/fingerprint caches were removed with path, Git and active-process checks.
- PRESERVED: seven dirty source files and 84 historical Markdown reports, with byte equality and SHA-256 manifests under `.reports/consolidation-20261101/`. The benchmark TODO is a symlink to an external Obsidian note that returned a read error; its external target remains untouched.
- PASS: debug FFI compilation with embedded Piper, using the verified installed ONNX runtime and one compiler job: 5m25s. Evidence: `ffi-build.log`. Existing PCM tests were subsequently moved into a separate file to respect the 500-line limit; final source-identity rebuild remains pending.
- BLOCKED: final core rerun returned 75 because another native build owns the shared lease. A concurrently created `epubtomp3-build-baseline-20261101` worktree must also be reconciled before removal. No active build was interrupted.
- PENDING: visible native application acceptance, PR/CI, remaining worktree integration and removal.

## 2026-11-01 — storage cleanup and approved packaging integration

- PASS: the canonical directory is the only remaining EPUB directory under
  Developer and the only Git worktree; 13 extra roots removed after preservation.
- PASS: retained-file identity/hash records and all 73 symlinks checked; original
  dirty work, complete native packages, model artifacts and evidence retained.
- PASS: 7.74 GiB net disk recovery; final storage preflight reports approximately
  80.50 GiB free and 0.96 GiB build caches, with no guard weakening.
- RED: original ONNX/eSpeak scripts fail both repeated-work regressions.
- GREEN: canonical packaging/XcodeGen suite: 22 tests, 148 assertions, no failures,
  errors or skips. Repository preflight and diff check passed.
- MERGED after required exact-head CI: packaging commit `8f75ed55637c26c8342ba7b5439df1aae75d66e4`,
  PR #1038, merge `95e499d322c4422529ccbbf65ea357ce01086e68`. No new local
  compilation or app/device execution during cleanup.
- PENDING: functional reconciliation of the older WIP snapshots and the main
  uncommitted silence-processing changes; final native acceptance. Historical
  results above have not been rerun against those combined sources.

See [storage cleanup](storage-cleanup.md) for local evidence and recovery paths.

## 2026-11-02 — final shared-core silence regression

Baseline: `c1240e0e37`; scoped generated-speech implementation on
`fix/generated-speech-silence-20261102`. Local compilation was explicitly
authorized after the user confirmed no matching verified prebuilt was available.

- PASS: storage preflight and the safe `clean:build` path before compilation;
  no guard weakening, model installation, Simulator or device action.
- RED: restoring the previous unprocessed synthesis-sink behavior makes the
  actual MP3 duration regression fail (exit 101). The candidate source was
  restored byte-for-byte before the final run. Evidence:
  `.reports/consolidation-20261101/resume-silence-red.log`.
- GREEN: guarded `cargo test --locked -p converter-core --lib --jobs 1`:
  **318 passed, 0 failed, 1 ignored**, execution 20.79 seconds. The ignored
  case is the existing manual JSON-cache benchmark. Coverage includes PCM/WAV
  compaction, unchanged MP3, quiet samples, exact thresholds, idempotence,
  structural pauses, cancellation, replacement and persistent cache identity.
  Evidence: `resume-core-green.log` and `resume-core-identity.json` in the same
  local evidence directory. The first dependency/core compilation took 7m35s;
  this is build time, not an app startup or synthesis benchmark.
- PASS: workspace Rust formatting, final whitespace check and repository
  preflight (19 host workflow steps). The existing PCM tests were extracted
  unchanged into `pcm/tests.rs`; all scoped source/test files are below 500 lines.
- PASS: 84 indexed historical Markdown files still match their retained SHA-256
  records. This verifies file integrity, not current app behavior.
- PENDING: final FFI/app rebuild and audible/native acceptance, explicitly
  deferred by the user until the implementation list is finished. The required
  SE1/iOS 15.5 acceptance remains prohibited by Simulator quarantine.

The unrelated nested mise edit is excluded from this delivery. No broader VAD
or noise-removal behavior is claimed.

## 2026-11-02 — delivery verification

The [delivery table](../../RESUME_CONSOLIDATION.md#integrated-deliveries) records
PRs and exact merge commits. #1040, repaired #1037 and #1041–#1047 all merged
after their required exact-head CI gate passed. Local master was fast-forwarded
after each integration; unrelated nested mise bytes remained unchanged.

| Responsibility | Executed local evidence | Result |
| --- | --- | --- |
| Generated-speech silence (#1040) | `resume-silence-red.log`, `resume-core-green.log` | Actual duration regression fails before fix; 318 core tests pass, 1 existing manual benchmark ignored |
| Callback boundary (#1037) | `callback-foundation-{red,green,preflight}.log` | Missing-source RED; Foundation XCTest: 208 executions, 15 existing opt-in skips, zero failures, including all five boundary cases |
| Linux-only SDK (#1041) | Actual mise resolution plus task-wiring suite | RED before fix; 29 tests / 247 assertions pass; no Android compilation on Mac |
| PID fixture (#1042) | Controlled empty-inode RED and supervisor suite | 15 tests / 86 assertions pass |
| TypeScript metadata (#1043) | Real compiler tests plus guarded Web validation | Distinct identities, same-size edits, error recovery and truncated metadata verified; lint/build pass |
| Capacity fixture (#1044) | Two RED cases, wiring and storage suites | Focused 2/9, wiring 31/256 and storage 21/116 pass; production low-space refusal retained |
| Web narration (#1045) | `web-native-reviewed-validation/`, `web-native-late-start-red.log`, `web-native-reviewed-preflight.log` | Original UI RED and two late-start RED cases; 287 pass, 2 existing skips; lint/build/preflight pass |
| Web queue (#1046) | `web-queue-{red-verified,green,preflight}.log`, `web-queue-validation/` | 8 expected RED failures; focused 11 pass; complete suite 298 pass, 2 existing skips; lint/build/preflight pass |
| Web product copy (#1047) | `web-copy-{lint,tests,preflight}.log` | Existing Hero/i18n tests: 50 pass; lint/whitespace/preflight pass |

Paths in this table are relative to `.reports/consolidation-20261101/`; raw logs
remain local. Each row reports its owning runtime/source stage, not a single
combined app acceptance run. Web builds bundled the versioned WASM artifact;
Rust/WASM was not rebuilt locally for the Web presentation changes.

An initial Web preflight hit the supervisor cancellation fixture timeout while
checks overlapped. The isolated fixture passed (1 test / 3 assertions), then final
preflights were run sequentially and passed. A scoped-index stale baseline was
rejected during product-copy delivery; the index had no staged content, scoped
bytes were unchanged, and a fresh capture/stage/verify passed before commit.
No guard or merge requirement was weakened.

Read-only current native package audit: five retained Intel receipts inspected,
zero current source/build identity matches. The five latest inspected trusted
producer runs predate silence integration. Evidence:
`native-final-package-audit.json`. No old binary was installed or accepted.

Pending acceptance/implementation:

- Final FFI/app rebuild, visible macOS/iPhone and audible silence/native-Web
  journeys, deferred by the user. No startup improvement is claimed.
- Required SE1/iOS 15.5 acceptance remains blocked by Simulator quarantine.
- PDF narration parser integration, chapter/page-label contract and regressions.
- Flutter playback/reader integration and actual Linux runtime checks on Arch.
- Isolated native player accessibility and optional startup instrumentation.
- Arch pull/cleanup and any separately authorized runtime/device round.

The 84 historical Markdown hashes still establish retained-file integrity only.
Models, books, original source/evidence and useful retained packages were preserved.
