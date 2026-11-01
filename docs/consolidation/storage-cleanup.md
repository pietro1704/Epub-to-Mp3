# Mac workspace storage cleanup — 2026-11-01

## Verified outcome

- Only `/Users/pips/Developer/epubtomp3` remains among EPUB directories in Developer.
- Eight linked worktrees and five historical temporary/preservation directories
  were removed. The stale, already-missing `/private/tmp` worktree registration
  was pruned. Retained Git branches were not deleted.
- Net free-space increase: **7.74 GiB**. Final storage preflight: approximately
  **80.50 GiB free**, **0.96 GiB project build caches**, no storage refusal.
- **140,992 regular files** and **73 symlinks** were retained and checked. Regular
  files have SHA-256 records and preserved filesystem identity; all retained
  symlinks resolve. Authenticated native packages and receipts are retained
  intact, including copies indexed under canonical `target/native-prebuilt`.
- Existing models were reconciled into canonical `models`; no conflicting model
  or native-package bytes were overwritten. Books, outputs and app data were not
  removed. Arch was not changed.

## Local evidence and recovery

The private evidence root is `.reports/consolidation-20261101/storage/`:

- `plan.json`, `preserved.json`, `removed.json`: original source/HEAD/status,
  exact retained paths, hashes, disposal classifications and removal receipts.
- `retained/<original-directory>/committed-source.tar`: original committed code
  for each removed worktree; the corresponding Git branch remains available.
- `retained/<original-directory>/working-tree.patch`: original dirty tracked diff.
- `retained/<original-directory>/files/`: dirty and untracked sources, models,
  reports, XCTest result bundles, screenshots, startup proposals and runtime
  artifacts. Private notes stay local.
- `final-audit.json`, `canonical-artifacts.json`, `retained-link-mapping.json`:
  post-removal checks, canonical artifact reconciliation and link verification.

The operation retained non-cache files with hard links before removal, checked
source identity/status again under the native lease, and refused unexpected
source changes. Discarded content consists of regenerable dependencies, generated
projects, web bundles and compiler intermediates. Retained build products are
historical artifacts; their presence does not prove compatibility with current
sources or replace receipt validation.

## Build tooling verification

PR [#1038](https://github.com/pietro1704/Epub-to-Mp3/pull/1038), commit
`8f75ed55637c26c8342ba7b5439df1aae75d66e4`, merged as
`95e499d322c4422529ccbbf65ea357ce01086e68` after required exact-head CI, ports the approved incremental
ONNX/eSpeak packaging and reduced Xcode environment logging to the canonical tree.

- Original packaging scripts: **2 tests, 2 expected failures** for repeated work.
- Corrected full suite: **22 tests, 148 assertions, zero failures/errors/skips**.
- Includes actual macOS signature/copy operations and generated Xcode descriptor
  comparison. No new native compilation was performed.
- Repository `mise run preflight` passed. `git diff --check` passed.
- Local `mise.local.toml` disables implicit installation; `mise settings get
  auto_install` returned `false`. Android tooling remains owned by Arch.

## Pending functional work

Filesystem consolidation does not claim functional integration of unvalidated
snapshots. The prior main/Flutter/Web WIP (`7cb696d9d0`), model-download WIP
(`6318856d3a`), old build-cache proposal (`3911c6ec26`), protected-pauses asset
(`5a48f78370`) and callback/PDF investigation (`ff91fa703b` plus dirty sources)
remain recoverable through their branches and retained snapshots. Resolve their
overlap with newer master code before adopting them; do not merge old snapshots
wholesale. The approved packaging changes are the verified integration in this
slice.

The main working tree still contains the previous uncommitted silence-processing
implementation and its tests, and the unrelated nested mise edit. They were not
included in the packaging commit. Final native rebuild/acceptance and remaining
functional integration are pending. Startup timing remains a proposal. No app
speed improvement is claimed. The Arch pull/cleanup is a later step.
