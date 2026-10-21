# Reader opening profile

## Evidence navigation and limits

- [Readiness correctness prerequisite](#readiness-correctness-prerequisite).
- [Mac active-chapter integration: behavior verified, budget still red](#mac-active-chapter-integration-behavior-verified-budget-still-red).
- [2026-10-12 Xcode 16.4 iOS 15.5 verification](#2026-10-12-xcode-164-ios-155-verification).
- [2026-10-12 AppKit geometry and exact iOS 15.5 retest](#2026-10-12-appkit-geometry-and-exact-ios-155-retest).

These links locate dated scope and later checkpoints. The record does not establish current source/build identity or close acceptance left pending in its final checkpoint.

> **Historical record (reviewed 2026-10-21).** Historical profile ledger. Invalidated geometry and mixed-toolchain build failures are not test results; final geometry evidence does not close the actual-app 200 ms target. controls_usable is a specific metric, not whole-app readiness. Use [execution policy](../agents/execution-policy.md) for current scope, guarded builds and Simulator quarantine, and [runtime navigation](../agents/runtime-navigation.md) for architecture; old commands and authorizations are retained only as evidence.

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

## iOS projection source replacement race (2026-10-11)

An actual iPhone SE (1st generation)/iOS 15.5 app relaunch reported a missing
prepared projection despite an archive for the active book and ordinal. Inspection
of the app container showed that the archive's saved source inode was older than
the fulltext cache file, which had been atomically replaced afterward. The parsed
fulltext save and projection write ran in separate detached tasks, so either could
finish last. The cache now saves the payload and then writes its source-bound
projection in one ordered utility task. A regression replaces the source and
requires a fresh projection read to return the replacement chapter.

Focused native verification on the exact Simulator passed 4 tests with zero
failures/skips: the fulltext/projection ordering test, both active-chapter reader
tests, and compact full-player UI coverage. The UI test now dismisses the full
player at the end, so its persisted presentation state is clean. `mise run
mac:run` built and launched the native macOS app; the LOTR reader was opened at
Chapter 12. Temporary profile logging was removed after diagnosis.

The actual app relaunch now validates the prepared projection and hits the
prepared renderer cache when reader progress is present. The same-path
uninstrumented LOTR repeat on the exact Simulator measured 231.120 ms to readable
content and 287.074 ms to controls, both still over 200 ms. A prior uninstrumented
repeat was 223.445/276.772 ms. An instrumented launch showed projection validation
at ~23 ms, `reader_load_task_started` at ~228 ms, renderer restoration ~37 ms, and
readable content ~320 ms; instrumentation is diagnostic and is not the acceptance
measurement. The remaining measured delay is before the reader task begins, with
another ~50 ms from renderer completion to readable content. APP21 remains open.

## iOS startup prewarm and restoration scheduling experiments

On the exact iPhone SE / iOS 15.5 Simulator, three uninstrumented actual-app
relaunches with recent-book prewarming enabled measured readable/controls at
251.727/320.248, 245.560/310.462, and 228.602/288.150 ms. With only the startup
prewarm invocation disabled, three sequential relaunches measured 283.753/353.800,
254.891/313.193, and 262.861/323.563 ms. The disabled variant's medians were
17.3/13.1 ms slower. Run order and simulator variability prevent a causal claim;
there is no evidence to disable prewarming, so retain the current active-book
exclusion policy.

The detached restoration experiment passed the two native active-chapter tests,
but three subsequent actual-app relaunches measured 246.245/302.621, 237.420/299.249,
and 261.983/328.969 ms. Its medians were 0.7 ms slower for readable content and
7.8 ms faster for controls than the enabled-prewarm baseline. Sequential samples
do not establish a speedup; the experiment was reverted. Source-bound projection
I/O/validation remains detached, and attributed archive restoration remains on
MainActor. A temporary actual-app stage trace placed projection validation at
about +9 ms, root `viewDidLoad` between +25 and +108 ms, load-task scheduling at
+2 ms but its MainActor start at +190 ms, renderer restoration between +192 and
+251 ms, readable content at +293 ms, and controls at +371 ms. Many repeated
render-marker writes perturbed the run, so these timestamps only locate ordering;
they are not acceptance measurements. The next slice moves secure archive decode
into a background restore worker while keeping TextKit application and final
viewport layout on MainActor. Re-measure the actual app without logging; the 200 ms
gate remains open.

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

## 2026-10-11 review update (fixed point: `HEAD` `fabdc8daf2`, current worktree)

### Standards/spec review

- The prepared chapter carries source/style identity; reader generations fence
  late projection/catalog completions, and the source is checked before the
  projection is presented. Navigation remains gated on full catalog hydration.
- iOS controller tests cover active chapter restoration and same-book/reentrant
  presentation; the UI harness now uses the visible active reader and visible
  page indicator when chrome is hidden. The seeded LOTR UI regression passed on
  the exact iPhone SE (1st generation)/iOS 15.5 (one test, zero failures/skips).
- Focused native macOS reader tests passed 13/13. The Mac app displayed LOTR
  chapter 12; full Mac clipping/chrome/page-turn geometry sequence is still open.
- The actual iOS app, relaunched twice with the persisted LOTR and no test launch
  arguments, recorded readable content at 289.380 and 280.652 ms, controls at
  335.980 and 331.630 ms. Both exceed the unchanged 200 ms requirement. The
  separate two-host controller tests (151.5–160.8 ms, with delayed fulltext
  hydration) are not evidence that the production app meets the requirement.

### Required follow-up

Keep APP-20261008-07 / APP-20261009-21 open. The worktree does not satisfy the
actual-app warm relaunch budget or complete the Mac geometry gate. Preserve the
source/style validation and catalog-gated navigation constraints while profiling
the real app's remaining startup-to-reader delay.

## 2026-10-11 follow-up: stable iOS opening viewport

The root previously changed the active reader's bottom constraint when loading
finished: initial pagination used a 460 pt height and the final mini-player
layout used 400 pt. The app could publish the first page and then repaginate
after the mini-player appeared. Loading now reserves the final mini-player
geometry while keeping its view hidden until content is ready. The active
reader/player IDs are excluded from recent fulltext prewarming; the root also
skips a duplicate fulltext-title read when the reader itself will hydrate that
book. The mini-player cover uses the existing bounded thumbnail cache and
background decoder rather than synchronously decoding the original image.

Exact iPhone SE (1st generation)/iOS 15.5 verification passed 11 focused tests,
zero failures/skips, including the real seeded LOTR page-turn/chrome/clipping UI
test. Temporary debug logs confirmed pagination starts at the final 320x400
viewport after the geometry change; logs were removed before final measurement.
The production app was then terminated and relaunched twice, with no test launch
arguments and the same saved LOTR chapter. It still misses the 200 ms gate:
readable content 515.964 / 513.673 ms and controls 590.184 / 590.574 ms. The
corresponding journey IDs are `5645F70A-A579-4C76-8385-F411162D3429` and
`87DCEB37-3C01-4888-A225-22C7F9EA8B8B`. These measurements show correctness and
stable geometry, not a latency improvement. Continue profiling the production
launch path; do not weaken the 200 ms threshold or source/style validation.

## iOS relaunch scheduling diagnosis (2026-10-11)

Exported both passing verification attachments from
`.reports/mobile-audio/reader-relaunch-ios15-20261011/first/verify.xcresult`
and `repeat/verify.xcresult` on the exact iPhone SE (1st generation)/iOS 15.5.
LOTR chapters 8–9 reached `controls_usable` in 157.765 and 151.505 ms; Christie
chapters 6–7 reached it in 160.128 and 160.833 ms. For LOTR, the reader task was
scheduled at 10.617/9.865 ms and started at 130.525/124.253 ms, a 119.908/114.388
ms gap. Projection snapshot read plus validation completed in 0.439/0.416 ms.
Prepared renderer lookup and reuse then took about 20.5/21.5 ms; initial reader
view load completed by 10 ms and initial layout by 15–21 ms. The repeated stage
profile points to a delayed MainActor task start after reader setup as the largest
measured interval in this relaunch path.

The separate uninstrumented real-app Foreword journeys at ~590 ms include a
different opening path and are not a replacement measurement for the chapter
8–9 process-relaunch gate. Next experiment: launch the validated projection read
independently of the reader's MainActor load task, preserving source/style checks,
load-generation cancellation, saved-position fidelity, and catalog-gated
navigation. Add native regressions before integration. This diagnosis changes no
implementation and claims no latency improvement.

### Projection worker experiment and follow-up stages

The iOS controller now captures the saved progress entry before scheduling a
detached task that reads and validates the source-bound projection and complete
catalog. The MainActor rechecks source identity and load generation, then restores
the style-bound renderer and commits the captured position against final geometry.
The focused iPhone SE/iOS 15.5 active-chapter tests pass 2/2, including the
saved 0.6 offset and mismatched-catalog fallback. A new assertion confirms the
worker validated the projection before catalog hydration starts. The renderer
restore has optional start/end stage markers for timing evidence.

The unchanged 200 ms two-host assertion remains red. Three iOS 15.5 verification
runs measured LOTR/Christie at 175.907/798.957 ms, 523.937/228.822 ms and
597.082/241.340 ms. In the last run, projection validation completed at 21.028
and 12.063 ms, before MainActor reader-task start at 531.892 and 134.139 ms.
Renderer restore itself took 55.525 and 24.431 ms; Christie then spent about
81 ms reaching final readable layout. Raising the load task to `.userInitiated`
did not produce repeatable improvement and was reverted. The worker removes
projection I/O/validation from the MainActor critical section, but measured
readiness remains variable and is not an accepted performance fix. Next diagnose
MainActor availability and the Christie layout interval, preserving the 200 ms
gate and exact source/style checks.

## 2026-10-11 iOS key-window and real-app follow-up

An activation probe found that the previous synthetic `UIWindow(frame:)` was not
the key window. The relaunch harness now attaches its measured reader to the
foreground `UIWindowScene` and asserts the reader window is key. Two independent
two-host repeats passed unchanged 200 ms for both books:

| Verification | LOTR | Christie |
| --- | ---: | ---: |
| `app21-ios15-key-window-gate` | 121.542 ms | 140.816 ms |
| `app21-ios15-key-window-repeat` | 123.491 ms | 139.551 ms |

The controller-level gate uses real prepared source/archive inputs and a visible
reader in the key scene, but it does not include the production app root startup.
A clean `simctl terminate` + `simctl launch` of the actual app with persisted LOTR
recorded `readable_content` at 325.127 ms and `controls_usable` at 374.767 ms
(`6DF7D668-1BDF-4216-BE08-D2AB3C08E3E0`). The app was visually confirmed on LOTR
Foreword, page 1/11. Therefore the root production warm-relaunch requirement is
still red. Next instrument the actual root-to-reader path and optimize its
measured cost; do not treat the passing controller-only gate as completion.

The key-window harness still overrode the scene frame to 390x844 points, while
the exact iPhone SE scene is 320x568 points. The two controller-only passes above
are therefore invalid for device-geometry acceptance and remain diagnostic only.
Next use `windowScene.coordinateSpace.bounds` without overriding the scene's
size, then re-run the same source-bound two-host gate. A clean-app internal stage
profile recorded MainActor reader-task start at 195.467 ms, renderer restore at
23.074 ms, first paginated layout at 42.582 ms, another layout at 40.487 ms
before readable content, and controls at 431.642 ms. This is direct evidence
that both MainActor scheduling and repeated TextKit layout need attention.

## 2026-10-11 Background renderer restore and launch interaction

Secure attributed archive decoding now runs on the renderer worker actor; UIKit
attachment, source and style revalidation, saved-position restoration, and final
viewport layout remain on MainActor. Startup restoration also enables reader
controls in the content-ready turn because no library-cell tap can be stolen;
library-initiated openings retain the deferred gesture path. Layout-mode
application now restores scrolling interaction even when the viewport geometry
matches its prior configuration.

On the exact iPhone SE (1st generation), iOS 15.5 Simulator, 10 focused native
tests passed (active chapter, launch restoration, root reader creation, and
renderer restoration). The seeded LOTR pagination/chrome UI test passed 1/1.
The native macOS app built and opened LOTR Chapter 12; 11 renderer and active
chapter tests passed on macOS 15.8.1.

Clean actual-app relaunches with the persisted LOTR book produced one three-run
set of readable/controls timings at 214.7/247.4, 212.0/236.8, and 203.3/227.7
ms. After the UI test, six more launches ranged from 287–617 ms to readable
content and 359–656 ms to controls. Every sample misses the unchanged 200 ms
acceptance, and the variance prevents a causal speedup claim. The last run was
visually checked on LOTR Foreword, page 1/11, with the app left open. Next isolate
the root startup to reader-task/first-layout interval on the real app, then
repeat the same-process-relaunch measurement; controller-level readiness and a
passing UI regression do not close APP21.

## 2026-10-11 first-layout projection delivery follow-up

The iOS reader can now consume a source/style-validated projection and prepared
renderer from a worker slot during its first committed layout. It defers saved
position restoration until a later, non-reentrant layout has a nonzero scrollable
extent. Focused native tests passed: active chapter 3/3, main reader 3/3, and root
presentation 6/6. The seeded LOTR pagination/chrome UI test passed 1/1 on the exact
iPhone SE (1st generation)/iOS 15.5 Simulator, including offset round trips. Its
XCTest execution succeeded, though saving the result bundle emitted an unrelated
attachment `mkstemp` warning.

An opt-in clean actual-app launch profile reported `readable_content` at 277.833 ms
and `controls_usable` at 346.685 ms. The prepared renderer was a cache hit and text
layout committed at 208.368 ms; the scheduled reader load task started at 249.452
ms. The profile therefore gives useful ordering but is not an uninstrumented
acceptance sample, and both readiness values miss 200 ms. A screenshot confirmed
LOTR Foreword page 1/11 rendered without visible clipping and the app remained open.

The native Mac app was rebuilt and opened to LOTR Chapter 12 with visible text and
controls using Xcode 26.3. `mise run mac:run` initially failed in the linker when
Xcode 16.4 was selected for the iOS Simulator workflow; the isolated Xcode 26.3
build succeeded. The Mac clipping/chrome geometry sequence remains outstanding.
Next isolate root overlay refresh work and MainActor task scheduling, repeat actual
app timings without the opt-in profiler, and complete the Mac geometry checks.

## 2026-10-11 final iOS timing and Mac runtime geometry follow-up

After removing a same-state root chrome transition and committing the scrollable
extent before restoring the saved anchor, three clean, uninstrumented relaunches
of the actual iOS app on the exact iPhone SE (1st generation)/iOS 15.5 Simulator
loaded persisted `prepared_disk` LOTR journeys. Readable/controls readiness was
188.820/192.236 ms, 181.533/183.900 ms, and 184.454/186.765 ms. Each individual
journey is below the unchanged 200 ms threshold; this is a three-run warm-path
sample, not a worst-case guarantee. The actual app was relaunched again without
re-seeding and left open on LOTR Contents 1/6 (`/tmp/app21-ios-resumed.png`).

The running native Mac app displayed LOTR Chapter 12 while the layout was switched
between Paginated and Scrolling. The reader was moved forward and backward, the
smaller serif size was exercised, and the window was resized to 1250x850 and its
1000x700 minimum. Captures showed readable text with no visible glyph clipping.
Mac has no immersive chrome toggle matching iOS, so that transition is not
applicable to this surface.

Focused native macOS XCTest ran 10 cases: text layout 2/2 passed, opening readiness
6/6 passed, and chapter navigation 1/2 passed. The deterministic failure is
`MacReaderChapterNavigationTests.testBackwardChapterCrossingAfterOpeningTableOfContents()`:
after crossing back, the observed clip offset is 5163 pt while the test derives
5167 pt from `text.frame.height - clipView.bounds.height`; eight subsequent
assertions cascade from the first offset mismatch. An isolated rerun reproduced
the same result. It does not prove that glyphs clip in the real LOTR UI, but it
means the Mac chapter-end geometry gate is not green and APP21 remains open.
Next inspect the clip view's legal visible extent versus the frame-derived end,
make the smallest correction at the actual navigation/layout seam if production
geometry is wrong (otherwise fix the test's expected extent), then rerun this
focused Mac suite and the real-app chapter-boundary check before closure.


## 2026-10-12 Mac chapter boundary follow-up

The existing worktree change makes chapter-end detection compare the clip view's
visible document rect with `NSLayoutManager.usedRect(for:)`, after ensuring text
layout. The focused regression now waits for reader controls, navigates through
the actual AppKit path, and checks visible glyph containment, legal scroll extent,
and persisted chapter identity/progress instead of requiring the frame-derived
scroll maximum. This addresses the observed 4 pt difference without treating it
as glyph clipping.

`xcodebuild test -project EpubToMp3.xcodeproj -scheme EpubToMp3Mac
-destination 'platform=macOS' -derivedDataPath ./.build
-only-testing:EpubToMp3Tests/MacReaderChapterNavigationTests` passed 2/2 with zero
failures/skips on 2026-10-12 (`Test-EpubToMp3Mac-2026.10.12_14-11-01--0300.xcresult`).
The current Debug macOS app launched (PID 7859), but the real-LOTR chapter boundary
was not manually exercised in this follow-up. iPhone SE/iOS 15.5 app exercise and
the remaining APP21 warm-open acceptance are still outstanding; do not close APP21
on this focused Mac XCTest alone.


### 2026-10-12 execution follow-up

Focused macOS reader verification was repeated with chapter navigation, opening
readiness, and text layout: 10/10 passed, zero failures/skips, result
`Test-EpubToMp3Mac-2026.10.12_14-34-44--0300.xcresult`. The actual Debug Mac app
process remained running (PID 7859); no manual LOTR chapter-boundary interaction
was recorded.

The exact iPhone SE (1st generation)/iOS 15.5 Simulator booted, launched the
existing compatible Debug app, and displayed the imported LOTR Contents 1/6; final
capture: `/tmp/auto-prompt-execute-ios15-final.png`. The named LOTR UI XCTest did
not start: `mise run ios:simulator:test` stopped because `vendor:python` is undefined
in the local mise config, and direct `xcodebuild test-without-building` could not
resolve the iOS 15.5 destination under active Xcode 26.3. This is a tooling/runtime
selection limitation, not a test failure. Keep APP21 open pending automated Mac LOTR chapter navigation and any remaining
warm-open acceptance evidence. The agent owns those checks; no user-run testing is
required.

## 2026-10-12 Xcode 16.4 iOS 15.5 verification

Added the missing `vendor:python` mise task used by `ios:simulator:test`. It runs
`mise install python` and verifies the project's pinned Python 3.12.10. The
interpreter and project `.venv` were already installed; `mise run vendor:python`
completed successfully and reported Python 3.12.10.

With `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer`,
`xcodebuild -showdestinations` resolved the exact iPhone SE (1st generation),
iOS 15.5 UDID `C66CCB36-C43E-4174-861E-2FA713389C84`. The official
`mise run ios:simulator:test` task then passed
`RealBookReaderUITests/testActualLOTRReaderPaginationAndChrome` 1/1 with zero
failures/skips in
`Test-EpubToMp3-2026.10.12_14-37-40--0300.xcresult`. It exercised the seeded LOTR
reader's pagination, chrome round-trip, clipping probe, and horizontal page swipe.
The app was relaunched and left open on LOTR, Note on the 50th Anniversary Edition,
page 1/14 (`/tmp/app21-ios15-xcode16-final.png`).

The focused Mac reader XCTest set had passed 10/10 under Xcode 26.3 earlier on
2026-10-12. Re-running it under Xcode 16.4 against the same shared `.build` cache
failed at link with `_swift_coroFrameAlloc` and newer-framework symbols unavailable
to Xcode 16.4; no Mac tests ran in that attempt. The cache was preserved. This is
a mixed-toolchain build-cache limitation and does not supersede the successful
Xcode 26.3 Mac test result. Automated interaction with the Mac app's real LOTR chapter boundary and APP21
warm-open latency acceptance remain outstanding. The agent owns running the next
UI automation or native test; do not hand verification steps to the user. APP21
stays open until that evidence passes.

## 2026-10-12 AppKit geometry and exact iOS 15.5 retest

Added `testActualLOTRBackwardChapterBoundaryKeepsLastGlyphVisible`, which reads
the imported LOTR fulltext, opens the real reader controller with an isolated
in-memory payload for the two chapters at the boundary, crosses backward and
forward, asserts the long previous chapter's final glyph is visible with no
large trailing gap, and checks persisted chapter offsets. Test setup evicts only
the process-warm fulltext copy, injects a no-op writer, restores defaults/progress,
and rewarms the original durable payload during teardown; it does not replace the
persisted source. `MacReaderTextLayout.fit` now includes the measured used-rect
bottom plus the trailing inset when committing the document height, accounting
for fractional AppKit paragraph geometry while retaining glyph visibility.

With Xcode 16.4 and isolated DerivedData `.build-app21-xcode16`, the focused Mac
chapter-navigation, opening-readiness, and text-layout suites passed 11/11 with
zero failures/skips. Result:
`Test-EpubToMp3Mac-2026.10.12_15-06-58--0300.xcresult`. The separate exact
iPhone SE (1st generation)/iOS 15.5 task reran the final sources:
`RealBookReaderUITests/testActualLOTRReaderPaginationAndChrome`: 1/1 passed in
21.848 s with zero failures/skips (`TEST EXECUTE SUCCEEDED`), result
`Test-EpubToMp3-2026.10.12_15-08-31--0300.xcresult`. The Simulator was relaunched
and left on LOTR Prologue, page 1/39 (`/tmp/app21-ios15-xcode16-final3.png`). The
Mac Xcode 16 Debug app was launched (PID 12855; library view screenshot
`/tmp/app21-mac-xcode16-final.png`). This closes the outstanding real-book Mac
chapter geometry evidence. The separate unchanged 200 ms actual-app relaunch
budget remains open; this geometry slice makes no new latency claim.
