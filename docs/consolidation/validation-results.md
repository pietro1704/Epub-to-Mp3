# Consolidation validation results

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
