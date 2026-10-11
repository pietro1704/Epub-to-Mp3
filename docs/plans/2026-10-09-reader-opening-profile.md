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

An additional two-host repeat is retained at
`.reports/mobile-audio/reader-relaunch-86F998D4-805C-4493-A999-99819BB90ED9/`.
Prepare passed 1/1; verify failed the unchanged 200 ms assertion (1 failed, zero
skips). It used the same source hashes and ranges, LOTR 8–9 and Christie 6–7,
with no synthesis. The candidate Debug executable SHA-256 was
`cf421252651a8dea894ff32a0c0fa41d73c578e943d450ba1b6ce718f3fdf193`; the
comparison field explicitly says the baseline executable was unavailable.

| Book | End-to-end test interval | readable_content | controls_usable | Resident / physical footprint |
| --- | ---: | ---: | ---: | ---: |
| LOTR | 355.265 ms | 261.333 ms | 261.588 ms | 115.4 / 49.0 MB |
| Christie | 145.430 ms | 125.247 ms | 125.368 ms | 98.3 / 54.0 MB |

The test interval starts before constructing and attaching the reader window;
the telemetry transition starts inside the reader lifecycle, so those clocks are
not interchangeable. Point-sampled resident/physical footprint is not peak
memory. This is a repeated diagnostic, not paired baseline/candidate evidence
or a performance fix; LOTR remains over budget on both reported clocks.

## Persisted source identity fast path (2026-10-11)

`PreparedReaderChapterStore.Snapshot` now persists the source file identity and
the SHA-256 signature already bound to the checked archive envelope. On a relaunch,
the store reads the source descriptor identity before and after the archive await;
an unchanged identity plus matching envelope signature skips the full-source hash.
Legacy snapshots or changed identities retain full SHA validation. A successful
same-content replacement refreshes the archived identity. Mutation, symlink,
oversize, and replacement-during-await cases remain fail-closed.

The new serialization assertion failed before the change and passed afterward.
Focused native macOS evidence: eight `PreparedReaderChapterStoreTests` and five
`MacReaderActiveChapterTests` passed, zero failures/skips. A separate-host actual
LOTR/Christie run used the same explicit book/range and input hashes, with no
synthesis. Prepare passed; verify failed the unchanged 200 ms assertion for LOTR
at 214.308 ms. The projection read took 3.104 ms, while the interval from
`reader_load_task_scheduled` to `reader_load_task_started` was 96.365 ms. Christie
completed in 96.083 ms. Evidence and attachments:
`.reports/mobile-audio/reader-identity-8F946CA8-5542-4C90-A94B-E9A6AD093D08/`.
The repeated verify attempt is invalid because the prior verification cleaned up
its fixture; it is excluded. This confirms the unchanged-source hash is no longer
on the projection-read path, but the end-to-end target remains unmet.

Remaining: variable reader-task scheduling, initial window construction, iOS
presentation parity, and repeated real-book evidence with the complete 200 ms
gate. Do not claim APP21/APP28 or the overall goal complete.

## iOS integration gap confirmed by source review

`BookOpenScreenController.loadBook()` currently awaits a full
`LocalFulltextCache.read(bookId:)` payload decode (or complete
`EpubFallbackParser.parseAsync`) before calling `restorePreparedChapter(in:)`.
Consequently, `PreparedChapterRenderer` can avoid HTML rendering but cannot avoid
the full-payload critical-path decode after relaunch. This is distinct from the
completed Mac active-projection race above. iOS needs projection-first presentation
with source/style validation, generation fences, saved-position fidelity, and
catalog-gated navigation/controls, followed by native UIKit and actual-book
verification. Source was inspected on 2026-10-09; at that time the paired iPhone
was unavailable and Simulator verification was not authorized. The later explicit
authorization allowed exact iPhone SE first-generation/iOS 15.5 Simulator checks:
the shared projection-store suite passed 8/8, and the real app opened the hash-
verified LOTR EPUB to its paginated contents page. This does not add the missing
iOS projection-first presentation path or complete clipping/chrome/page-turn
verification. The 200 ms two-host gate remains open.

## Cooperative projection cancellation

APP-20261009-29 adds cancellation checkpoints before source descriptor access,
between bounded 64 KiB reads and after hashing; write also checks before decode,
encode and archive handoff. Its original implementation hashed the source on
both sides of the archive await; the later single-scan optimization preserves
source mutation rejection through descriptor identity checks after that await.
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

## Isolated route cost measurement

APP-20261009-30 added an opt-in native test comparing the actual projection store
read (both SHA passes + archive read/decode) against binary catalog decode and a
separate file-read-plus-decode path on a detached worker. The original hash-checked
LOTR/Christie EPUBs were parsed only for setup; chapter ordinals 8/6 and isolated
temporary source/archives were used. No synthesis or modifications to originals.
Complete payload/chapter/title/author/TOC equality and source-byte preservation
were asserted. Three bounded, alternating samples per route; OS caches not flushed.

Executed native macOS Debug test: one passed, zero failed/skipped, in
`.reports/mobile-audio/reader-relaunch-7E788A03-052D-4427-83E0-DBEA08AF3DE8/projection.xcresult`.
Permanent attachment: `native-projection-validation-versus-catalog-decode.json`,
exported in that report's attachments directory. The JSON records individual
samples, source SHA256, ordinal, binary byte count, platform/OS and explicit limits.

| Book | Binary bytes | Projection read median | Decode-only median | File read+decode median |
| --- | --- | --- | --- | --- |
| LOTR | 26535207 | 188.377 ms | 118.920 ms | 130.781 ms |
| Christie | 2051490 | 15.822 ms | 11.613 ms | 12.877 ms |

This disproves treating the current source-bound projection as a cheaper isolated
read path on this host. It does not separate SHA CPU cost from archive decode, prove
concurrent-route contention or include first-window/layout/progress/playback controls.
Three samples are diagnostic, not statistical before/after proof. No production
behavior changed; do not weaken integrity or mark the 200 ms gate complete.
Next work must address the validation/storage design or measured presentation cost,
not blindly replicate the expensive projection race in the iOS adapter.

## Concurrent projection priority probe

APP-20261009-31 compares requested high/utility priority for a concurrent projection
read, with catalog file-read/decode always high priority. Three samples per book;
pair order alternates high→utility, utility→high, high→utility. Timing ends at
catalog delivery. Losing validation is cancelled and drained before the next sample.
Payload equality, input SHA and source bytes remain checked; setup/render/UI excluded.

Native macOS Debug result: one passed, zero failures/skips in
`.reports/mobile-audio/reader-relaunch-8F611ACD-515F-4F8F-ABD7-7356EAD59FE1/projection.xcresult`.
The permanent exported attachment records priority order, requested priorities,
OS/platform, literal hashes, individual timings and limits. Initial fixed-order
probe is retained in `reader-relaunch-ACF7FD04...`, not used as final evidence.

| Book | Isolated read/decode median | With high projection | With utility projection |
| --- | --- | --- | --- |
| LOTR | 134.581 ms | 135.608 ms | 142.431 ms |
| Christie | 13.193 ms | 12.906 ms | 13.568 ms |

This sample does not demonstrate a benefit from utility priority or a large median
contention penalty. Three samples/requested priorities do not establish scheduling
guarantees or statistical significance. Production remains unchanged. The full
opening budget is still red; source-validation design and first-window/readiness
costs need stronger evidence before another optimization is shipped.

## Read scheduling and file mapping follow-up

APP-20261008-07 added optional per-stage timestamps to the native Mac relaunch
integration. The measured candidate starts full-catalog and source-bound projection
reads before clearing the reader and attaching its window; its consumer still
presents the first validated chapter and waits for the complete catalog before
marking controls usable. Two actual two-host repeats prepared and reopened the same
hash-checked LOTR/Christie inputs without synthesis:

| Run | Book | Outer interval | Readable from request | Controls from request | Catalog read start → finish |
| --- | --- | ---: | ---: | ---: | ---: |
| `66CFCBBD-044E-4710-9132-AAD0B60E7CC9` | LOTR | 230.065 ms | 117.588 ms | 159.186 ms | 70.956 → 210.775 ms |
| `F79FFDB1-20F5-4B33-8914-3359368CFB9A` | LOTR | 239.957 ms | 133.512 ms | 171.221 ms | 68.891 → 221.927 ms |

Both verification runs fail the unchanged outer 200 ms assertion; no clock was
redefined. Before this scheduling change, a nearby instrumented run reported 315 ms
outer and 246.6 ms controls, but samples are unpaired and do not prove causation.
The actual Mac app was launched and opened LOTR chapter 12; the exact iPhone SE
(1st generation)/iOS 15.5 Simulator app was installed/launched with the seeded LOTR
contents visible. The Mac reader suite passed 13/13, zero skips in
`Test-EpubToMp3Mac-2026.10.11_11-40-00--0300.xcresult`; complete reader geometry
verification remains open.

A two-host no-projection experiment measured LOTR 236.569 ms outer, 167.711 ms
readable and 167.872 ms controls; it does not show a meaningful gain over concurrent
projection, which remains necessary for earlier readable content. A native
three-sample file-read/decode comparison checked decoded-payload equality:
`Data(contentsOf:options: .mappedIfSafe)` medians were 114.1 ms vs 119.5 ms ordinary
for LOTR and 12.6 ms vs 12.4 ms for Christie. Mapping is not a demonstrated fix.
Evidence: `reader-relaunch-BD825F5D-CDD9-45D3-846E-10CE0555608A` and
`reader-relaunch-92A8BF36-B8D8-465E-AA5E-0DDFFB11FAE0`.

The next useful seam is the size and decode shape of the validated full catalog;
neither dropping projection nor memory mapping satisfies the strict relaunch budget.
Keep the 200 ms gate and source integrity unchanged. The two-app clipping/chrome/
page-turn gate also remains incomplete.

Review — 2026-10-11: Standards review found the change remains in the native Mac
reader, keeps source validation/catalog gating intact, and has focused XCTest
coverage. Spec review found no acceptance shortcut: both end-to-end LOTR samples
remain above 200 ms and full reader geometry is unverified. Required follow-up is a
validated catalog/decode improvement plus the unchanged two-host and two-app gates;
do not mark APP-20261008-07 or APP-20261008-02 complete.

## Prepared catalog metadata and deferred full decode

The prepared active-chapter snapshot now stores lightweight metadata for every
chapter (index, name and content kind) inside the existing source-hash-bound
archive. At open, the Mac reader presents the prepared chapter and restores the
saved position first. Once the committed layout callback fires, it rechecks the
source file's descriptor identity against the validated snapshot, records controls
usable, and only then releases the utility-priority full catalog read/decode. Chapter
navigation stays disabled until that catalog arrives; complete catalog mismatch
replaces the projected presentation. Older snapshots without the index take the
full-catalog-first path. The active source identity is runtime-only and is omitted
from the archive so identical-byte atomic replacement remains recoverable.

Focused macOS XCTest: 21 passed, zero failures/skips in
`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.11_12-18-03--0300.xcresult`.
Three successive same-input two-host LOTR/Christie relaunch executions passed the
unchanged 200 ms verification assertion: LOTR 191.552, 195.079 and 194.885 ms outer
latency; latest controls readiness was ~184.947 ms and full catalog start ~185.044 ms.
They are unpaired samples and the last run has only ~5 ms margin, so this is a passing
candidate with fragile margin, not a stable improvement or completion of the latency
gate. Latest evidence is `.reports/mobile-audio/reader-relaunch-FD71E526-B227-4399-8C61-533E2AD44F0C`.

The current macOS Debug app built and launched. The exact iPhone SE (1st generation)
Simulator on iOS 15.5 remains available; the existing Simulator app artifact was
reinstalled and the same SHA-verified LOTR book opened to Contents page 1/5, with the
app left open (`.reports/reader-ios15-5-current.png`). `mise run ios:build` was
blocked by the scheme destination guard: this Xcode has no eligible iOS Simulator
destination because iOS 26.2 platform is unavailable. The installed artifact predates
this source change, and the full clipping/chrome/page-turn sequence was not exercised.
The complete two-app reader geometry gate and iOS projection-first integration remain
open; no overall reader acceptance is claimed.

## Readiness measurement correction (2026-10-11)

The run-loop wait was not a valid latency endpoint: XCTest resumed 1.104 s after the
reader had already reported `controls_usable` at 185.718 ms. The measurement now uses
the recorded `controls_usable` timestamp, and the macOS test waits on that callback
directly. An integration assertion ties the report point to that timestamp and keeps
the 200 ms limit unchanged. Optional AppKit lifecycle stage markers locate load,
configure, layout, and appearance boundaries for future diagnosis.

Two separate Release two-host executions, each prepared and verified in different
XCTest processes with the same real LOTR/Christie inputs and ranges, passed 1/1 with
zero failures or skips. LOTR readiness measured 186.676 ms and 178.608 ms; Christie
measured 61.720 ms and 62.534 ms. Reports:
`.reports/mobile-audio/reader-direct-readiness-release-36BE15E5-22B0-49FA-990E-23DA90DCC388/`
and `.reports/mobile-audio/reader-direct-readiness-repeat-1DB107C0-99B2-4851-9D1C-B119873AD321/`.
These runs establish two macOS passes with modest LOTR headroom; they do not establish
an iOS process-relaunch measurement or a stable worst-case bound.

In both LOTR profiles, `reader_load_task_scheduled` preceded
`reader_load_task_started` by about 92 ms (92.071 and 92.454 ms). The task began
about 72 ms after initial layout, then readable content and controls followed in
about 21 ms. This repeatable interval is the next diagnostic target, but the
headless AppKit/XCTest harness does not establish that the production event loop
has the same delay. Profile the real app's main run loop before changing scheduling.

Current-source native verification also passed: the actual LOTR pagination/chrome UI
test passed 1/1 on iPhone SE (1st generation), iOS 15.5 under Xcode 16.4, including
forward/back swipes and two chrome offset round trips; app remains open on LOTR.
`mise run mac:run` built and launched the Debug app, and the real LOTR opened to
Chapter 12 in the macOS reader. The Mac screen was inspected; the full clipping and
chrome geometry sequence was not run there. Overall APP21 remains open pending
iOS process-relaunch latency parity and the complete two-app geometry gate.
