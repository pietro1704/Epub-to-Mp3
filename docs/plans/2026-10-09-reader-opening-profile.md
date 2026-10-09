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
