# EpubToMp3 consolidation: resume plan

Snapshot verified on 2026-11-01 on the Mac. The user explicitly requested this
plan and its supporting consolidation documents on GitHub. It is not a new
source of execution authority. Revalidate the checkout and follow the
current user request and applicable AGENTS.md before acting.

## User objective and current limits

Keep only the canonical `~/Developer/epubtomp3` directory on the Mac. Integrate
valuable work from the removed copies, retain organized Markdown test evidence,
finish silence processing, and improve CLI build feedback. Later, update and
clean the Arch checkout. Filesystem cleanup is finished; functional integration
is not finished.

The user runs the app through `mise`. Native recompilation remains deferred
until the user asks for it. Do not start a build, download a runtime/model, boot
Simulator, or change the Arch host just to resume this plan. Earlier permissions
must be checked against the user's later no-compilation instruction. Simulator
remains quarantined. Arch was explicitly deferred; the intended later step is
Git pull/cleanup. Resolve any need for additional Arch runtime execution before
expanding that scope.

## Verified current state

- Canonical root: `/Users/pips/Developer/epubtomp3`.
- Session working directory: `ios/EpubToMp3` inside that root.
- Only one EPUB directory remains under `~/Developer`, and only one Git worktree
  is registered. Thirteen extra directories were removed after preservation.
- Net disk recovery: 7.737 GiB. Final storage preflight passed with about
  80.50 GiB free and 0.96 GiB of project build caches. Recheck before any build.
- Retained-file audit checked 140,992 regular files and 73 resolving symlinks.
  Models, complete native packages/receipts, dirty source files, test result
  bundles and screenshots remain inside the canonical project.
- Local `mise.local.toml` sets `auto_install = false`, is excluded from Git,
  and was checked with `mise settings get auto_install`.
- No new native build, model download or app/device validation was performed
  during this cleanup. Arch was not changed.

### Delivered packaging change

- PR: https://github.com/pietro1704/Epub-to-Mp3/pull/1038 — **MERGED**.
- Feature commit: `8f75ed55637c26c8342ba7b5439df1aae75d66e4`.
- Merge commit: `95e499d322c4422529ccbbf65ea357ce01086e68`.
- Approved changes: skip redundant verified ad-hoc ONNX copy/sign operations,
  skip unchanged eSpeak resource copies, and suppress Xcode environment dumps
  in four script phases. Compiler settings and safety guards were not weakened.
- Original packaging scripts failed both repeated-work regressions. Corrected
  suite: **22 tests / 148 assertions / zero failures, errors or skips**, including
  actual macOS signature/copy tools and XcodeGen descriptor comparison.
- Repository preflight passed. Required PR CI passed before automatic merge.
  This does not assert comprehensive post-merge CI or visible-app acceptance.
- Public technical documentation: [build feedback](docs/build-feedback.md).

### Git and dirty-work warning

At the pre-publication snapshot, HEAD was on local branch
`perf/consolidate-incremental-packaging-20261101` at `8f75ed5563`. Its remote
branch was deleted after merge; `[gone]` was expected. Local `master` and
`origin/master` pointed to `95e499d322`. Publication starts on a documentation
branch from that master; recheck current refs. Uncommitted implementation includes:

- Modified: `crates/converter-core/src/lib.rs`, `src/pcm.rs`, `src/tts_session.rs`.
- New: `crates/converter-core/src/speech_silence.rs`, `src/pcm/tests.rs`,
  `src/tts_session/speech_silence_tests.rs`.
- Modified unrelated edit: `ios/EpubToMp3/mise.toml` adds a nested Codex tool entry.
  Preserve it; do not silently include it in another change.
- Consolidation documentation was initially untracked; this documentation-only
  delivery publishes it and this plan. The Rust/mise changes remain outside it.

The silence-processing work predates the cleanup and remains uncommitted. Do not
reset, clean, overwrite or drop these files when moving to a fresh feature branch
from current master. Preserve and reapply owned changes with an explicit scope;
do not recreate the removed sibling worktrees as a shortcut.

## Recovery and evidence map

Read [the consolidation index](docs/consolidation/README.md),
[inventory](docs/consolidation/integration-inventory.md),
[validation results](docs/consolidation/validation-results.md),
[silence contract](docs/consolidation/silence-processing.md), and
[storage cleanup](docs/consolidation/storage-cleanup.md).

Private evidence root: `.reports/consolidation-20261101/`. Cleanup-specific
evidence is in its `storage/` subdirectory:

- `plan.json`, `preserved.json`, `removed.json`, `final-audit.json`: source
  identities, retained paths/hashes, disposal classifications and removal audit.
- `retained/<old-directory>/committed-source.tar`: original committed source.
- `retained/<old-directory>/working-tree.patch`: original dirty tracked changes.
- `retained/<old-directory>/files/`: dirty/untracked code, models, runtime outputs,
  reports, screenshots, test results and proposals. Git branches were preserved.
- `canonical-artifacts.json`: native-package/model reconciliation without
  conflicting overwrites. Canonical packages are under `target/native-prebuilt`.
- `packaging-red.log`, `packaging-green-focused.log`, `packaging-green.log`:
  actual packaging regression evidence.

Host preflight evidence: `.reports/host-workflow/20261101T165922-84706/`.
Startup timing is an **unapplied proposal**, retained under
`storage/retained/epubtomp3-audit-delivery/files/.reports/startup-timing-proposal/`.
Historical logs are not tests of the final combined app. Retained binaries must
pass source/platform/architecture/recipe identity checks before reuse.

## Atomic delivery rules

For each implementation slice: inspect current architecture and source deltas,
create a scoped branch from current master while preserving existing edits,
add meaningful runtime regression coverage, run the relevant checks, inspect the
final diff, then commit/push/open the PR. Merge only after the required exact-head
CI passes. Finish that PR before beginning the next delivery. Keep unvalidated
implementation local. This plan and its supporting documents are explicitly
authorized for GitHub publication. Keep credentials, private notes and raw
evidence local; reference their paths and sanitized results only.

Native compilation-dependent validation remains pending until the user requests
the build round. Read-only inventory and patch preparation can continue, but
preparation is not delivery. Honor the current prebuilt-binary question and
storage/toolchain rules when that build round is authorized.

## Ordered atomic plan

- [ ] **1. Classify retained work.** For each changed responsibility, identify
  already-integrated, superseded and still-needed behavior. Record exact files,
  dependencies and acceptance. Do not merge whole old snapshots: newer master
  overlaps substantially with them. Main WIP `7cb696d9d0` includes Flutter/Web
  work; model WIP is `6318856d3a`; old build-cache WIP is `3911c6ec26`.
- [ ] **2. Reconcile test documentation.** Index preserved results, distinguish
  historical checks from current verification, and reconcile reader-note/backlog
  updates with master. Keep private/session details local; publish only suitable
  technical documentation through a scoped delivery.
- [ ] **3. Settle the silence contract.** Current uncommitted code compacts runs
  of digital zero of at least 600 ms to 300 ms, preserving nonzero samples and
  separately inserted structural pauses. It is not VAD/noise removal. Clarify
  broader silence-detection expectations before changing that scope. The old
  protected-pauses WIP `5a48f78370` contains Silero weights/license, not a connected
  application implementation; no new model installation is authorized.
- [ ] **4. Deliver Rust silence processing.** Review existing implementation and
  regressions; verify speech preservation, structural pauses, WAV/MP3 limits,
  cancellation, session replacement and cache identity. Prior logs report a
  315-pass core run and a focused 6-pass run, but a final rerun/rebuild was pending.
  Do not present those historical runs as current combined-app acceptance.
- [ ] **5. Reconcile callback diagnostics.** Compare retained commit `ff91fa703b`
  with master. Deliver only the missing behavior, testing valid/invalid callbacks
  and stale session identity. Its original worktree also had unrelated dirty work.
- [ ] **6. Resolve PDF investigation.** Inspect retained `ingestion/pdf_text.rs`,
  Cargo/Swift package edits and `MacPatristicaOpeningTests.swift`; determine what
  remains necessary. A retained source file is not evidence of a connected or
  verified feature. Any required fix gets its own known-input/failure regression.
- [ ] **7. Reconcile model catalog and selection.** Compare `6318856d3a` with
  current catalog/model-library code. Preserve identifiers, explicit selection and
  bounded fallback; test available, missing and incompatible models.
- [ ] **8. Reconcile model download/installation.** Deliver only missing resume,
  cancellation, partial-file and integrity behavior. Verify existing models and
  unrelated transfers survive failures. Do not install real models automatically.
- [ ] **9. Review remaining build/cache proposals.** Compare `3911c6ec26` with
  current tooling. Adopt only justified improvements that preserve guards and
  reject stale binaries. Do not redo PR #1038 or enable the rejected XcodeGen
  cache. Respect platform ownership for Flutter/Gradle changes.
- [ ] **10. Integrate necessary Flutter playback changes.** Separate playback
  state/transport/backend changes from reader geometry; verify replacement,
  cancellation and actual Linux audio behavior on Arch when authorized.
- [ ] **11. Integrate necessary Flutter reader changes.** Independently verify
  pagination, reading position and navigation. Native Apple reader changes, if
  discovered, require their own reader skill/contract and acceptance limitations.
- [ ] **12. Integrate necessary Web changes.** Reconcile native speech fallback,
  playback presentation and queue behavior; run focused success/failure tests.
  Preserve listening-only native fallback and Piper-only MP3 export policy.
- [ ] **13. Deliver optional startup measurement.** Review the preserved
  `-measureStartup` proposal. Keep it off by default and preserve startup flow.
  Clearly distinguish setup completion from a displayed first frame; do not
  invent performance gains or add overlapping durations.
- [ ] **14. Authorized final builds and real-app acceptance.** Revalidate retained
  packages and source identity, run storage preflight/safe cleanup, then build only
  what is necessary under the native guard. Exercise affected actual app flows,
  including audible silence behavior and startup measurements. Simulator remains
  prohibited; required SE1/iOS15.5 acceptance stays blocked until separately
  reauthorized. App build/launch alone does not prove all runtime behavior.
- [ ] **15. Later Arch update/cleanup.** Inspect remote status and preserve its
  unique edits/models/evidence first. Pull delivered changes and review the exact
  cleanup targets. Never run an indiscriminate `git clean -fdx`. Clarify any
  runtime testing beyond the user's stated pull/cleanup-only intention.

## First action for the next agent

Read current AGENTS.md and execution/delivery policies, then inspect Git status,
worktrees and the retained inventory. Resume at step 1; do not repeat the physical
cleanup or the merged packaging work. Ask only about a material unresolved scope
or authorization decision. Update checkboxes and actual evidence as work passes,
leaving unavailable validation explicitly pending.
