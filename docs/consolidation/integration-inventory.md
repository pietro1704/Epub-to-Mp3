# Integration inventory — 2026-11-01

Baseline: `525a9bd96a2bbc9a23304d3cbed7884b09c9e07b` (`origin/master`).

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
included. No retained branch was deleted. Historical integration statuses above
remain pending where stated; removing a worktree does not integrate its code.

The approved ONNX/eSpeak incremental packaging and Xcode environment-log changes
were ported to the canonical working tree and delivered separately in PR #1038,
commit `8f75ed55637c26c8342ba7b5439df1aae75d66e4`. Machine-local automatic tool
installation is disabled. See [cleanup evidence](storage-cleanup.md).
