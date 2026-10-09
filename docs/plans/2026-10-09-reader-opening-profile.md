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

## Mac active-chapter integration: behavior verified, budget still red

The actual Mac controller now races validated chapter projection and complete
catalog delivery. If the catalog wins it is used without awaiting projection.
If the chapter wins, the complete real chapter and saved viewport are presented
first; controlsUsable still waits for catalog validation. No placeholder chapters
are synthesized. Hydration checks chapter/count/TOC/title/author and installs a
matching catalog without repainting. Mismatch invalidates pending presentation
callbacks independently of load generation. Appearance during restore is applied
before saved position; protected TOC selection cannot reopen the chapter.
Closing after snapshot restoration may persist its visible position.

Canonical EPUB anchors can be published from the actual chapter, independent of
reader ordinal. Existing array-based publication retains its normalization and
sentence reset. Projection preparation is best-effort utility work and deduplicated
per load/ordinal; cache write failure does not hold readiness.

Native behavioral evidence: the initial blocked-hydration test failed before
integration (`04-23-02`). Nine cases passed in the wider 10-case run (`04-35-32`),
with one mismatch-fixture expectation corrected afterward. Mismatch and early-close
cases passed in a focused two-case run (`04-37-31`); all five active-chapter cases
passed after first-arrival scheduling (`04-44-36`). No failures/skips in those
focused passing bundles. Existing readiness and chapter-boundary cases were included
in the wider run. Only relevant native macOS XCTest filters were executed.

Actual LOTR/Christie two-host relaunch, same source/audio hashes and chapter 8/6,
no synthesis: prepare passed, verify failed the unchanged 200 ms assertion.
Initial serialized projection-first observation: LOTR 462.757 ms, Christie 154.023 ms
(`reader-relaunch-0C986C52-ADE6-4502-A990-BC87EDDD5571`). First-arrival observation:
LOTR 363.818 ms, Christie 151.933 ms
(`reader-relaunch-5E61AC9C-5B83-4152-83DD-5173B9B71F89`). Permanent attachments record
app-code identity, original input hashes, journeys and point-sampled memory.
These unpaired observations do not establish a general causal speedup.

Remaining: full-source hashing/decode and first-window scheduling costs, iOS
presentation parity, controlled real-book before/after evidence and the complete
200 ms gate. Cancellation can discard losing callbacks but does not interrupt the
store's synchronous hashing. Do not claim APP21/APP28 or the overall goal complete.

## Cooperative projection cancellation

APP-20261009-29 adds cancellation checkpoints before source descriptor access,
between bounded 64 KiB reads and after hashing; write also checks before decode,
encode and archive handoff. Descriptor guards, SHA validation on both sides of
the archive await and source-mutation rejection remain intact.
The previous two pre-cancelled operations still returned/wrote content (native
red `05-00-10`). Final Mac store tests: seven passed, zero failed/skipped
(`05-01-22`). iOS 16: the two new cancellation cases passed, zero failed/skipped
(`simulator-smoke-3AA1639C-870F-4985-A123-E2A11F186D6D`).

These tests prove cancelled entry rejection and preservation of existing source/
archive bytes, not a measured speedup or bounded cancellation wall time. A write
already handed to the archive actor may still commit; cancellation is not a
transactional rollback. The unchanged opening baseline remains LOTR 363.818 ms /
Christie 151.933 ms. Rust worker cancellation, iOS presentation parity, measured
hash/decode costs and the full 200 ms acceptance remain open.
