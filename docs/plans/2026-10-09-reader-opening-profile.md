# Reader opening profile

Same original LOTR/Christie sources, selected chapter 8/6, two distinct native
macOS XCTest hosts, no synthesis or edits to originals/models/downloads.
The 200 ms across-relaunch acceptance stays unchanged and failed.

Evidence: `reader-relaunch-BA5A57B5-3D14-4EE3-9FCB-02F49C86408A`,
`reader-relaunch-CC1B4F3C-0A87-4D66-BBF4-F31902D9F4AC`, and
`reader-relaunch-9DBFB08C-CC19-48D8-9744-57C1A9A631CF` under `.reports/mobile-audio`.
Exported diagnostics contain actual timing lines, not source-contract checks.

LOTR observations: full payload disk read/decode 129–131 ms; archive restoration
hit true, 4.9–5.2 ms; state/table setup including restoration 22.6–23.5 ms;
chapter presentation 4.4–5.6 ms. Last run's cumulative controller/window milestones:
construction 55.7 ms, attached 76.6 ms, key/front 93.1 ms, first layout 93.1 ms.
Christie read/decode ~14 ms, archive hit ~2.9 ms, state/restore ~50 ms and
presentation ~11 ms; cumulative first layout ~31 ms.

Durable attributed archive is being used: HTML fallback is not this observed
bottleneck. Whole-book cache decode and first-window setup/scheduling consume
the remaining budget. Timings overlap and cannot be added as independent costs.
Do not redefine the opening clock or relax 200 ms to get a pass.

Next seam: a safely validated active-chapter/readiness payload should avoid full
book decoding on the critical path while remaining bound to source and style.
Need actual controller readiness, invalidation/corruption and later navigation
regressions; a cache sidecar alone is not sufficient. No such implementation or
budget completion claimed here. All temporary `[DEBUG-reader-stage] probes removed.

## Readiness correctness prerequisite

APP-20261009-24 repairs the macOS readiness clock: `readableContent` and
`controlsUsable` now follow final layout and saved-position application instead
of preceding a queued restore. Native red evidence showed offset 0 when readiness
was already published, versus the expected saved 33600.6. A second red case
showed closing during preparation overwrote the saved fraction 0.6 with 0.

Pending opening no longer writes that temporary viewport or accepts page-turn
commands. Queued restoration rejects old load generations, publishes the actual
clamped chapter, and handles a reload before restoration without losing progress.
Completion precedes persistence of any newer chapter selection.

Final verification: `APPLE_NATIVE_TESTS=EpubToMp3Tests/MacReaderOpeningReadinessTests,EpubToMp3Tests/MacReaderChapterNavigationTests`
with `mise run apple:chapter-callback:test`; six passed, zero failed/skipped.
Bundle: `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_02-36-12--0300.xcresult`.
iOS stable-layout completion is unchanged; Flutter has no macOS AppKit adapter.
This is correctness evidence, not a new latency measurement or a 200 ms pass.

Next integration remains a separate real active chapter while fulltext hydrates,
with no empty placeholder chapters. Navigation, cross-document links and playback
must await a validated complete catalog; hydration cannot repaint or rewind the
already visible passage. Both Apple adapters need native lifecycle/navigation
tests before the two-host actual-book budget can be accepted.
