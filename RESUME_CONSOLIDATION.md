# EpubToMp3 consolidation: resume plan

Status reconciled on 2026-11-02 through PR #1065, with scoped native and
Flutter/Linux verification recorded below. This user-requested plan and
its supporting documents are published technical status, not execution authority.
Follow the current request, AGENTS.md and execution policy before continuing.

## Objective and current limits

Keep the canonical `~/Developer/epubtomp3` checkout, preserve valuable work from
removed copies, integrate useful changes in atomic PRs, and improve build feedback.
The user requested sequential TODO execution and deferred final visible/audible
app validation until the implementation round is finished. Local compilation of
the shared Rust silence change and subsequent PDF runtime was explicitly authorized
after the source/platform-matched prebuilt questions.

Filesystem consolidation is complete. The reconciled Rust, host/build and Web
changes below are integrated. Text-layer PDF narration is now implemented and has focused macOS acceptance.
Flutter playback and viewport pagination are integrated through #1064–#1065;
accessibility is integrated through #1061. Optional setup timing is integrated
through #1062 and disabled by default. Final combined-app/iPhone acceptance
remains pending; Pietro deferred physical-iPhone testing until after implementation.

- Preserve the unrelated `ios/EpubToMp3/mise.toml` Codex tool entry.
- Keep models, books, complete packages, source snapshots and evidence intact.
- Use the native guard, storage preflight/safe cleanup and one compiler job.
- Revalidate source/platform/architecture/recipe identity before binary reuse.
  The earlier retained-package audit found no matching Intel FFI receipt. The PDF
  task subsequently authorized a local Piper-enabled FFI build; its current native
  source/product identity and focused test results are retained locally.
- Simulator remains quarantined. Required SE1/iOS 15.5 acceptance is blocked.
- Android/Flutter Linux belong on Arch. Flutter/Linux reconciliation and a safe
  checkout/cache audit were subsequently authorized and performed there.
  Android remains paused; no model installation or Android device action occurred.
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

Later source/merge identities were verified through Git. CI was not monitored
during the Flutter continuation, as requested; no new CI-status claim is made.

| PR | Change | Merge commit |
| --- | --- | --- |
| [#1060](https://github.com/pietro1704/Epub-to-Mp3/pull/1060) | Upright PDF covers and lazy legacy-cover repair | `82701d8de7ee22e1b32de1c9bf15d28c042048fd` |
| [#1061](https://github.com/pietro1704/Epub-to-Mp3/pull/1061) | Persistent Mac player accessibility | `e56f1f3882f4990842d5203f9ae348cad73c6aad` |
| [#1062](https://github.com/pietro1704/Epub-to-Mp3/pull/1062) | Optional synchronous startup diagnostics | `9c78f210ba679ca56393328ecbf33126416e9a3b` |
| [#1063](https://github.com/pietro1704/Epub-to-Mp3/pull/1063) | Hosted unsigned iPhone validation archive | `c8b73325d2c377dc8eafcbf3e0b1a228146c7086` |
| [#1064](https://github.com/pietro1704/Epub-to-Mp3/pull/1064) | Desktop decoder and truthful playback lifecycle | `6b807b4f482a4a55ee46c9538ef7f35940c3c74c` |
| [#1065](https://github.com/pietro1704/Epub-to-Mp3/pull/1065) | Complete-line viewport pagination and source-anchor retention | `425558e4fc807213f2541f1d10ba1a8a34cb40f8` |

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
- [x] **6. Integrate text-layer PDF narration.** Shared Rust format dispatch,
  `pdf-extract 0.12.1`, outline/page-label fidelity, cancellation and validated MP3
  publication are implemented. Focused core/FFI and native macOS PDFKit/Faber/
  Luciana acceptance passed; see the [PDF contract](docs/pdf-conversion.md).
  Image-only or mixed pages requiring OCR fail explicitly; OCR is not installed.
  Mac cover rendering and lazy repair are integrated in #1060. The old
  private-book/absolute-coordinate probe remains historical.
- [x] **7. Reconcile model catalog/selection.** The relevant `6318856d3a` work
  already landed via #969 (`2ead9a9f76`) and later catalog/FFI/UI improvements.
- [x] **8. Reconcile model download/installation.** Resume, cancellation, crash
  recovery and integrity behavior already exists; do not restore superseded UI.
  No model was installed locally during this resumption.
- [x] **9. Review remaining build/cache proposals.** #1041–#1044 complete the
  justified host/cache changes after #1038. Release incremental/LTO changes are
  unmeasured and not adopted. XcodeGen caching remains rejected. The old combined
  runtime wrapper and broader process-supervision proposal remain unapplied.
- [x] **10. Flutter playback implementation.** #1064 reconciles the retained desktop
  backend/transport work. On Arch, 559 unit/widget cases pass with 8 intentional
  skips, plus an opt-in real-decoder lifecycle/replacement/recovery case.
  Whole-app conversion/audible acceptance remains separate from this decoder check.
- [x] **11. Flutter reader implementation.** #1065 adds rendered-line pagination,
  raw-anchor retention and scrolling fallback. All 54 focused reader cases pass
  again on the integrated #1064 base. See the
  [viewport contract](flutter_app/VIEWPORT-PAGINATION.md).
  The unused character-budget paginator and its private tests are retired;
  `ReaderPage` now belongs to the active viewport paginator module.
- [x] **12. Web reconciliation.** #1045–#1047 integrate native playback presentation,
  queue phase handling and current product copy. Native speech stays listening-only;
  Piper remains required for MP3 export. Audible browser acceptance is pending.
- [x] **13. Native diagnostics and accessibility implementation.** Optional `-measureStartup`
  setup timing is implemented and disabled by default; see the
  [timing contract](docs/native-startup-timing.md). Deterministic native tests and
  visible Mac setup acceptance cover the process flag, library decoder and shipping
  window seam. These are inclusive synchronous intervals, not first-frame timing
  or measured speedup. Persistent-player accessibility is integrated in #1061
  with isolated AppKit regressions and focused visible acceptance; collapsed transport and
  retired content are excluded. Combined-app acceptance remains pending.
- [ ] **14. Final combined-app builds and real-app acceptance.** The broader round
  remains pending. Focused PDF macOS acceptance has passed with native tests and
  visible/audible fixture conversion; it does not close the remaining iPhone or
  combined silence/reader/provider journeys.
  Revalidate/build the necessary FFI/app targets under the guard, then exercise
  actual macOS/iPhone flows and audible silence behavior. Inspect source identity,
  provider/voice, cancellation and retained outputs. A green XCTest/build is not
  the visible journey. Simulator quarantine keeps required SE1 acceptance blocked.
- [x] **15. Arch update/cache audit.** The isolated working checkout and the shared
  local `master` ref reached `425558e4`; the dirty original checkout remains on
  its own branch with unchanged status hash. No superseded compiler caches were
  found in the inspected linked worktrees, so zero files/bytes were removed.
  Unique work, models, virtual environments and evidence were retained. Only the
  two newly created, tree-verified integrated feature branches were removed.

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
