# EpubToMp3 consolidation: resume plan

Status reconciled on 2026-11-02 through PR #1047. This user-requested plan and
its supporting documents are published technical status, not execution authority.
Follow the current request, AGENTS.md and execution policy before continuing.

## Objective and current limits

Keep the canonical `~/Developer/epubtomp3` checkout, preserve valuable work from
removed copies, integrate useful changes in atomic PRs, and improve build feedback.
The user requested sequential TODO execution and deferred final visible/audible
app validation until the implementation round is finished. Local compilation of
the shared Rust silence change was authorized after the prebuilt question.

Filesystem consolidation is complete. The reconciled Rust, host/build and Web
changes below are integrated. PDF narration, Flutter, native accessibility/startup
proposals and final app acceptance remain pending; this list is not fully done.

- Preserve the unrelated `ios/EpubToMp3/mise.toml` Codex tool entry.
- Keep models, books, complete packages, source snapshots and evidence intact.
- Use the native guard, storage preflight/safe cleanup and one compiler job.
- Revalidate source/platform/architecture/recipe identity before binary reuse.
  None of the five inspected retained Intel FFI receipts matches current inputs;
  the five inspected trusted producer runs predate the silence integration.
- Simulator remains quarantined. Required SE1/iOS 15.5 acceptance is blocked.
- Android/Flutter Linux belong on Arch. Arch remains deferred; its earlier intended
  pull/cleanup scope does not authorize new runtime, device or audio work.
- Source builds outside the already authorized runtime scope retain the project's
  prebuilt-availability question. Do not install models automatically.

## Integrated deliveries

Each PR below merged after its required exact-head CI gate passed. This does not
assert comprehensive post-merge CI or final visible/audible app acceptance.

| PR | Change | Merge commit |
| --- | --- | --- |
| [#1038](https://github.com/pietro1704/Epub-to-Mp3/pull/1038) | Incremental ONNX/eSpeak packaging and quieter Xcode scripts; delivered before this resumption | `95e499d322c4422529ccbbf65ea357ce01086e68` |
| [#1040](https://github.com/pietro1704/Epub-to-Mp3/pull/1040) | Conservative generated-speech silence compaction | `e802167d31f7b8c6d205b0e5a583d903f5c8e5c8` |
| [#1037](https://github.com/pietro1704/Epub-to-Mp3/pull/1037) | Callback boundary diagnostics and Foundation package/test wiring | `011c8de06196736b6086b866715a480ef0eb35f0` |
| [#1041](https://github.com/pietro1704/Epub-to-Mp3/pull/1041) | Android SDK selection restricted to Linux | `8d03b6f29a6312f40585bd6876a4feaa34d53849` |
| [#1042](https://github.com/pietro1704/Epub-to-Mp3/pull/1042) | Nonempty PID readiness in supervisor fixtures | `f45e321faa957dab928699d4c4263f5b08e5e9e0` |
| [#1043](https://github.com/pietro1704/Epub-to-Mp3/pull/1043) | Separate incremental TypeScript check/build metadata | `d363367950af9d99f6c42be5caf3bd7308ed9e6d` |
| [#1044](https://github.com/pietro1704/Epub-to-Mp3/pull/1044) | Hermetic build-capacity fixtures with low-space refusal preserved | `2350d17b704a1a151a3fdccd9f4317757296de30` |
| [#1045](https://github.com/pietro1704/Epub-to-Mp3/pull/1045) | Actual native-speech state/voice in the Web player, owner isolation and localized failure handling | `1ff2a8dc3dc84361253b5b9c5064c9e2a0b56b3a` |
| [#1046](https://github.com/pietro1704/Epub-to-Mp3/pull/1046) | Correct terminal queue phase labels and replacement-book regressions | `bfcedd85977712efcc435a69bac9700b180f2c19` |
| [#1047](https://github.com/pietro1704/Epub-to-Mp3/pull/1047) | Remove obsolete Python/Edge product copy in English and Portuguese | `cbcb6cbbcbcd4bfdd733ef172095232b7801e62e` |

## Ordered TODO status

- [x] **1. Classify retained work.** File-level inventory distinguishes integrated,
  superseded and pending responsibilities. Never apply an old WIP snapshot whole.
- [x] **2. Reconcile historical test documentation.** All 84 indexed Markdown
  SHA-256 records match. Historical backlog snapshots remain historical; they do
  not replace the current TODO or prove current runtime acceptance.
- [x] **3. Settle the silence contract.** Runs of digital zero lasting at least
  600 ms retain 300 ms. Every nonzero sample and separate structural pause is
  preserved. No VAD/noise-removal scope or model installation was added.
- [x] **4. Deliver shared-core silence processing.** #1040; duration regression
  reproduced before the fix, then 318 core tests passed with one manual benchmark
  ignored. Final embedded app/audio acceptance remains in item 14.
- [x] **5. Reconcile callback diagnostics.** Existing PR #1037 was repaired and
  integrated, including stale identity and bounded diagnostic coverage.
- [ ] **6. Integrate PDF narration.** Investigation completed: native reading uses
  PDFKit, but `EmbeddedBookSession` still parses EPUB. The retained parser is
  disconnected, references missing `pdf_page_labels` and adds `pdf-extract 0.12.1`.
  Define chapter/label fidelity and known-input/error cases before selecting the
  dependency. The private-book/absolute-coordinate UI probe is historical only.
- [x] **7. Reconcile model catalog/selection.** The relevant `6318856d3a` work
  already landed via #969 (`2ead9a9f76`) and later catalog/FFI/UI improvements.
- [x] **8. Reconcile model download/installation.** Resume, cancellation, crash
  recovery and integrity behavior already exists; do not restore superseded UI.
  No model was installed locally during this resumption.
- [x] **9. Review remaining build/cache proposals.** #1041–#1044 complete the
  justified host/cache changes after #1038. Release incremental/LTO changes are
  unmeasured and not adopted. XcodeGen caching remains rejected. The old combined
  runtime wrapper and broader process-supervision proposal remain unapplied.
- [ ] **10. Flutter playback.** Retained `7cb696d9d0` still needs transport/backend,
  cancellation/replacement and actual Linux audio validation on authorized Arch.
- [ ] **11. Flutter reader.** Pagination/position/navigation need a separate Arch
  integration and runtime regression. No Flutter code was ported on this Mac.
- [x] **12. Web reconciliation.** #1045–#1047 integrate native playback presentation,
  queue phase handling and current product copy. Native speech stays listening-only;
  Piper remains required for MP3 export. Audible browser acceptance is pending.
- [ ] **13. Optional native proposals.** Keep `-measureStartup` unapplied until an
  isolated tested implementation is ready. It must remain off by default; setup
  completion is not first-frame timing, and nested spans must not be summed.
  The missing persistent-player accessibility child change also remains pending,
  with an isolated XCTest needed; the retained test requires current API and
  library/defaults isolation before reuse. Neither proposal is a measured speedup.
- [ ] **14. Final native builds and real-app acceptance.** Deferred by user request.
  Revalidate/build the necessary FFI/app targets under the guard, then exercise
  actual macOS/iPhone flows and audible silence behavior. Inspect source identity,
  provider/voice, cancellation and retained outputs. A green XCTest/build is not
  the visible journey. Simulator quarantine keeps required SE1 acceptance blocked.
- [ ] **15. Later Arch update/cleanup.** Preserve unique edits, models and evidence
  before pull/cleanup. Do not use indiscriminate `git clean -fdx` or infer runtime
  execution authority from earlier setup/pull permissions.

## Recovery and evidence

Read the [consolidation index](docs/consolidation/README.md),
[inventory](docs/consolidation/integration-inventory.md),
[validation results](docs/consolidation/validation-results.md),
[silence contract](docs/consolidation/silence-processing.md) and
[storage cleanup](docs/consolidation/storage-cleanup.md).

Raw evidence remains local in `.reports/consolidation-20261101/`; source snapshots,
patches, models, complete packages and original reports remain under `storage/`.
`resumed-inventory.json` and `resume-triage.md` record the file classification.
`native-final-package-audit.json` records the current retained-receipt identity
audit without installing or accepting an old binary. Historical report integrity
is recorded separately from runtime verification. Keep `TODO_APP.md` local.

Only the canonical checkout remains. Remove a completed local branch only after
checking its exact tree against the known integrated merge and verifying that
merge is an ancestor of master. Preserve all branches with unique work.

## Next continuation

Inspect current status and policies, preserve the nested mise overlay, and choose
one pending runtime slice with its required authorization/acceptance. Do not repeat
filesystem cleanup, model reconciliation or merged deliveries. Finish one scoped
PR and its required CI/merge before starting the next implementation item.
