# EpubToMp3 consolidation

Status: index reconciled on 2026-11-03 against the published 2026-11-02
checkpoint through #1065. This is a dated consolidation summary, not acceptance
of later changes or a live worktree inventory.

The canonical checkout is `epubtomp3`; isolated tasks may use linked worktrees.
Filesystem consolidation was completed at the recorded checkpoint. Revalidate
the current checkout/worktree state before new work rather than repeating cleanup.

The shared-core silence, callback, justified build/cache and Web changes were
integrated through #1047. The later checkpoint also records PDF cover orientation
and lazy repair (#1060), Mac player accessibility (#1061), optional startup timing
(#1062, disabled by default), and Flutter desktop playback and viewport pagination
(#1064–#1065). Other unadopted proposals retain their dispositions in the inventory.

Text-layer PDF narration has focused native macOS acceptance recorded for its
tested source. Final combined-app/iPhone and audible browser acceptance remain
pending in that checkpoint. Required SE1/iOS 15.5 acceptance remains blocked by
Simulator quarantine, and Android remains paused. Historical tests do not close
those checks or validate the current audit's implementation.
Focused Flutter/Linux checks also do not establish Windows or whole-app audible
acceptance.

- [Ordered execution and resume plan](../../RESUME_CONSOLIDATION.md)
- [Integration inventory](integration-inventory.md)
- [Validation results](validation-results.md)
- [Historical test reports](historical-reports.md)
- [Native PDF conversion contract](../pdf-conversion.md)
- [Generated-speech silence processing](silence-processing.md)
- [Storage cleanup and retained work](storage-cleanup.md)

Source snapshots and raw evidence remain local under
`.reports/consolidation-20261101/`. Preserve branches with unique work and retained
evidence. Current execution and safety rules remain in the
[execution policy](../agents/execution-policy.md).
