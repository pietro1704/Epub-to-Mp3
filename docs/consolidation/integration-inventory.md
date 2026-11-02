# Integration inventory

## Current reconciliation — 2026-11-02

Integrated through #1065; see the [delivery table and ordered TODO](../../RESUME_CONSOLIDATION.md).

| Retained responsibility | Current disposition |
| --- | --- |
| Main WIP `7cb696d9d0`: Web | Native speech state/voice, queue phases and obsolete product copy integrated in #1045–#1047 |
| Main WIP: Flutter playback/reader | Reconciled through #1064–#1065 on Arch; 559 compatibility cases plus a real-decoder lifecycle case, then 54 focused reader cases on the combined base. Whole-app/device acceptance remains separate |
| Main WIP: Mac player accessibility | Integrated in PR #1061 with isolated AppKit regressions and visible Mac acceptance |
| `ff91fa703b`: callback diagnostics | Integrated by repaired existing PR #1037, including Foundation package wiring |
| `6318856d3a`: model/catalog/download | Already integrated via #969 and later improvements; old UI superseded |
| `6318856d3a`: detached-descendant process cleanup | Separate unvalidated safety proposal; not adopted |
| `3911c6ec26`: packaging/cache | #1038 plus justified #1041–#1044 integrated; Release/LTO unmeasured, XcodeGen cache rejected, old combined wrapper unapplied |
| Dirty generated-speech silence | Integrated in #1040; final app/audio acceptance pending |
| Dirty PDF parser/probe | Text-layer Rust ingestion and conversion integrated in #1049; focused macOS PDFKit/Faber/Luciana acceptance passed. Cover orientation/lazy repair integrated in #1060. Private UI probe remains historical; iPhone acceptance is deferred |
| `5a48f78370`: protected-pauses | Weights/license retained; no connected compaction implementation to port |
| Startup timing proposal | Integrated in #1062, off by default; native flag/window/decode acceptance; inclusive scopes are not first-frame or speedup evidence |
| Historical reports/backlogs | 84/84 Markdown hashes verified; original bytes retained, no promotion to current acceptance |

File-level details remain local in `resumed-inventory.json` and `resume-triage.md`
under `.reports/consolidation-20261101/`. No old snapshot was applied wholesale.
No local Flutter/Arch runtime or final combined-app acceptance was performed during
the earlier resumption. The subsequent PDF task has focused native macOS and
audible fixture acceptance, recorded in the validation results.
The later Flutter continuation ran on an isolated Arch checkout. Its shared
`master` and clean working checkout reached `425558e4`; the original dirty
checkout remains intact. The scoped cache audit found no disposable compiler
intermediates and removed no data. Git confirms both Flutter merge identities;
CI status was not polled during this continuation.

## Historical pre-cleanup inventory — 2026-11-01

Baseline: `525a9bd96a2bbc9a23304d3cbed7884b09c9e07b` (master at that snapshot).

| Source | Verified inventory | Integration status |
| --- | --- | --- |
| Main workspace | `f4546e6698` is patch-equivalent to master; `7cb696d9d0` retains Flutter/Web and native work | WIP delta requires reconciliation |
| audit-delivery | `ff91fa703b`; four modified files and two untracked sources | Pending integration and tests; preserve dirty bytes |
| ios-background-audio | Same HEAD as baseline master | Code integrated; evidence must be retained |
| ios-reader-notes | HEAD ancestor of master; modified backlog and ignored notes/reports | Reconcile historical results with newer evidence |
| iphone-delivery | `863bd3878f` is patch-equivalent to master | Code integrated; native acceptance must be checked |
| protected-pauses | `5a48f78370` adds only Silero weights and license | No silence compaction implementation exists in this worktree |
| tts-benchmark | `6318856d3a` contains 71 changed files | Reconcile model catalog/download work with newer master |
| voicestudio | `3911c6ec26` contains 15 changed files | Export recovery already integrated; build/cache changes need reconciliation |

Patch equivalence was checked with `git cherry origin/master <branch>`, after fetching origin. A clean tracked status does not imply that ignored models, notes and test results are disposable.

## Resumption: filesystem cleanup

All eight linked worktrees and five historical temporary/preservation directories
were removed after source snapshots, dirty patches and non-cache files were
retained and checked. The audit baseline created during the other session is
included. No retained branch was deleted during that cleanup. The pre-cleanup
integration statuses above are historical; current dispositions are listed first.
Removing a worktree does not integrate its code.

The approved ONNX/eSpeak incremental packaging and Xcode environment-log changes
were ported to the canonical working tree and delivered separately in PR #1038,
commit `8f75ed55637c26c8342ba7b5439df1aae75d66e4`. Machine-local automatic tool
installation is disabled. See [cleanup evidence](storage-cleanup.md).
