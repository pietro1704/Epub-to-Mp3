# App quality and performance

Scope: repair every finding from the native app audit, in independently tested
and committed slices on `fix/app-quality-performance`, based on local develop
including verified embedded-audio prerequisites (`0d3a8229`). No remote merges.

## Ordered acceptance checklist

1. Durable library import: failed replacement preserves prior bytes and its
   bookmark target; same-file reimport is harmless; successful replacement is
   atomic. Native tests exercise the existing durable-import boundary.
2. Chapter scope: reject invalid nonempty selections before Rust/device work;
   support explicit single chapters and inclusive ranges; whole-book selection
   is intentional, never an error fallback.
3. Conversion configuration: provider/model/voice/language and supported flags
   reach Rust through a versioned FFI contract; unsupported choices fail clearly.
   Manual conversion must not change playback or autoplay. Native and Rust
   tests exercise configuration routing and reject silent defaults.
4. Segment playback: chapter-relative seek selects the right segment/local time;
   next chapter works when available only in the backlog and retains pending
   navigation when not yet available. Native player regressions required.
5. Adaptive TTS: size changes affect unsent work in the same chapter, preserve
   text/audio ordering, and honor request concurrency/cancellation. Controlled
   transport tests prove behavior; physical benchmarks measure the result.
6. Main-thread work: batch import/hash/copy/metadata, segment audio persistence,
   and history loading leave the interaction thread. Bound history reads and
   avoid repeated full-library persistence during a batch. Test preservation,
   queue ordering and responsiveness at real public boundaries.
7. Performance evidence: measure book-open, first audible audio, seek/navigation,
   memory and relevant IO costs before/after. Warm-open target is 200 ms; a
   telemetry-emission test alone cannot establish the budget. Record missing
   measurements explicitly rather than declaring targets achieved.

## Verification and constraints

Use actual mise tasks and focused native XCTest/Rust tests. Serialize heavy
work with the existing lease, terminate the previous
app before runs, and reuse the single incremental build cache. No local Python,
Ruff, osascript, CI/PR monitoring, model downloads or user-data cleanup.
Latest user correction supersedes physical-device preference: subsequent iOS
validation is Simulator-only, oldest compatible runtime and one small-screen
iPhone, no Xcode GUI or automatic iOS 18/26 fallback. Historical physical benchmark
measurements below remain evidence, but a simulator run is not a matched device
performance comparison. Runtime installation and Intel Rust artifact gates are
tracked in APP-20261008-12.
Fixture directories are exclusively owned and disposable; books, models and
offline listening downloads are preserved. Commit/push only verified slices.

Conversion baseline: physical iPhone 16e / iOS 27.0.1, run
`8EB8510F-B673-4804-BBA8-CFD53D0A24ED`, commit `0d3a8229` runtime lineage,
LOTR source hash `3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e`
chapters 8–9, Christie hash
`55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da` chapters 6–7.
Synthesis: 310.397 s / 6.339 s, no audio reuse. Reuse these exact inputs/ranges
for comparison, at most two chapters per book. Network variation and missing
memory baseline must be accounted for; do not infer a causal speedup from one
uncontrolled comparison or extrapolate whole-book duration.

## Progress

### UIKit reader reimport caller — asynchronous durable import

APP-20261009-32 fixes the remaining reader picker callback that waited on the
library's synchronous IO queue from MainActor. It now awaits importBookAsync,
including durable index flush, before updating the reader. Request UUID, original
book and session selection fence success/error; update(book:) invalidates pending
requests, including A→B→A. A stale import may stay in the library but cannot reopen
its reader, replace a newer selection or display an obsolete alert.

Native picker-delegate tests use real file copying in isolated storage. The copy
requests a MainActor heartbeat while blocked; the old synchronous caller fails its
deadline. Both cases failed before correction
(`simulator-smoke-76C409E3-B354-4FA7-B4F3-940268E08215`). Final iOS 16: two passed,
zero failures/skips (`simulator-smoke-EF153645-193B-46CE-8ACE-1D0D90C001A1`). Source
bytes and a fresh LibraryStore after flush are checked; one case changes the book
during preparation and confirms the newer selection remains.

Focused guarded Simulator build/test only; no TTS, original books/models/downloads
or shared import implementation changed. Injected session defaults affect only the
picker selection, not all reader settings/progress. Layout, Mac/Flutter paths and
the 200 ms gate remain outside this slice. Stale-error guards were reviewed but
do not have a dedicated runtime regression in this two-case verification.

### Reader preparation off the UI executor

APP-20261009-27 removes synchronous EPUB archive extraction from the UIKit loading
task. One shared parseAsync entry point runs the existing parser on an explicit
detached worker; the macOS adapter also uses it without a claim that its previous
nonisolated async function ran on main. UIKit rejects cancellation/book/generation
changes immediately after the new await, before font registration.

Native probes compare the complete parser payload and original source bytes,
assert the actual extraction thread is not main, and block the worker until a
MainActor heartbeat releases it. Red main-actor preparation: two failed, one
compatibility case passed (`04-04-55` macOS xcresult). Correct worker: three passed
(`04-06-39`). The initial iOS heartbeat failed its semaphore deadline while fidelity
and threading passed (`simulator-smoke-261611C0-11BD-422A-8E3F-272C35B681BA`).
The test was tightened to request the MainActor release directly from the worker,
without an intermediate XCTest observation; the two-second deadline remains.
That revised case passed separately on Mac (`04-12-43`) and iOS 16
(`simulator-smoke-09E7C00E-23A1-41E8-85FB-CC3C6911F9EE`), zero failures/skips.
Production remained unchanged during these test-only revisions.

Executed focused ReaderDocumentPreparationTests through apple:chapter-callback:test
and guarded ios:simulator:smoke:build/test. No synthesis, original-book changes,
model/download cleanup, Python/Ruff or CI/PR monitoring. This proves executor
placement and payload preservation, not real-book latency/memory improvement,
glyph/layout behavior, first-segment playback or 200 ms readiness. Detached parsing
does not inherit cancellation; old results are fenced, not claimed interrupted.
Mac cold-cache persistence and the remaining original acceptance gates stay open.

### Native iOS reader progressive Listen — complete-chapter bridge

APP-20261009-26 now requests the literal reader priority through the existing
Rust executor, resolves input asynchronously, and queues complete-chapter events
before the conversion returns. A job token fences duplicate Play, stale callbacks
and replacement sessions. Later events are deduplicated/ordered; the requested
chapter must be present before playback starts. Terminal manifests must retain
that priority/order before history registration. Finalization uses finishStreaming,
not play/resume, preserving the active media item and a user's pause. Error cleanup
is independent of the visible book and preserves audio already delivered.

Shared AudioPlayer.pause now revokes pending autoplay even before audio exists.
Session defaults are injectable for isolated native components; production still
uses standard defaults. The failed first fixture run was traced to app-host cleanup
removing its global book selection while input resolution awaited, not to a missing
file or audio transport failure. Tagged diagnostic probes were removed.

Executed evidence, iOS 16 SE Simulator with the Xcode 16.4 test controller:

- Controlled old wait-for-completion route: one test failed with requested start
  -1 instead of 1 (`simulator-smoke-05D04967-B054-4E62-8CFF-04698801D668`).
- Diagnostic: calls=0, selectedBookMatches=false, sourceExists=true, no player
  snapshot (`simulator-smoke-8A0B8724-D131-4BAF-8E05-7E83872B6587`).
- Production fix: seven cases passed, one failed only on the test's incorrect
  expectation that a replacement running session should have isConverting=false
  (`simulator-smoke-E656DF68-66B2-4F46-8533-A7F9B0B061BE`).
- The corrected replacement assertion passed in a one-case rerun, zero skips/fails
  (`simulator-smoke-86DB3D4C-119A-46C6-8A4D-403BCBDF7315`). Production code was unchanged.
- macOS shared pending-pause regression: one passed, zero skips/fails
  (`Test-EpubToMp3Mac-2026.10.09_03-42-31--0300.xcresult`).
- Final data-safety case: one passed, zero skips/fails
  (`simulator-smoke-437B1056-4B2F-4CC1-BACF-ACD6F0D535C4`), verifying a fresh
  ResumeStore preserves the previous meaningful 4-second position, wasPlaying=false.
  This covers the additional pre-teardown pause/persistence branch. The explicit
  persistence after pause also avoids its speech-fallback early return; the speech
  transport itself is not tested here. Total iOS cases: nine across seven + one + one.

The native controller tests use an isolated three-chapter EPUB, priority 1 and
two file-backed audio chapters (1–2); no provider or network synthesis. Actual
AVPlayerItem time advances on the requested file before the fake executor finishes.
They cover out-of-order/foreign delivery, duplicate Play, overflow, pause, book
change, replacement ownership, terminal priority and failure during browsing.
Commands: guarded ios:simulator:smoke:build/test with focused IOS_TESTS filters;
apple:chapter-callback:test with AudioPlayerPendingPlayIntentTests only. A host-load
guard refused one build; work resumed after cooldown without bypassing it.

Limits: these are command-seam/AVFoundation tests, not real-book speed measurements,
acoustic latency, UI gesture validation or glyph/layout evidence. Progress remains
by complete chapter, not first segment. FFI cancellation is not exposed by the
current native adapter; superseded work is fenced from playback but may still run.
Provider configuration, segment-first delivery, 200 ms relaunch and Flutter runtime
parity remain separate original-goal requirements. Rust/FFI/Flutter unchanged.

### Native Book Detail manual isolation — actual adapters verified

The audit found that both native Book Detail adapters still replaced playback on
manual completion; macOS additionally called stop. The manual branches now only
validate/register the conversion and refresh detail UI. Explicit Listen autoplay
is unchanged. A shared injectable executor delegates to the original embedded
Rust flow, preserving job, scope and callbacks; no FFI or provider defaults changed.

Native regressions call the actual manual entry points, suspend conversion and
complete it; macOS additionally receives progress/chapter callbacks, while iOS
manual conversion does not subscribe to them. An existing AVPlayer advances
through a generated silent WAV and retains snapshot, playing/converting state,
presentation and the same AVPlayerItem; idle playback stays idle. Conversion
history is flushed and verified through a fresh LibraryStore instance.
Mac red: both cases failed due to snapshot replacement (`02-43-03` xcresult).
Final Mac: two passed, zero failures/skips (`02-46-53`). iOS 16: two passed, zero
failures/skips (`simulator-smoke-38898F9F-EADD-488B-800A-E065CDBFC343`).
Executed `mise run apple:chapter-callback:test` with the focused class filter,
then the guarded Simulator smoke build/test with the same focused class; execution
used the Xcode 16.4 controller without rebuilding during boot. No network synthesis
or modifications to original books, models or listening downloads.

This closes APP-20261009-25 for the Apple detail adapters only, not global item 3.
Flutter parity remains on Arch. The iOS main reader's Listen route still waits
for a full conversion instead of receiving progressive callbacks (APP-20261009-26).
Chapter-first relaunch/200 ms and other original goal acceptance remain open.

### Prepared renderer signature reuse — correctness verified, latency still open

Memory lookup now reuses its caller's signature rather than reencoding the same
full chapter/settings; post-await source/style checks remain unchanged. Native
memory restoration preserves full attributed-string equality and object independence.
Five Mac and five iOS16 renderer tests passed (zero failures/skips; iOS `65B9724B...`).
Latest same-input two-host test `reader-relaunch-8670ECE5-1408-4B4D-B91F-7E99BBA52222`:
prepare passed, verify failed unchanged 200 ms gate. LOTR outer readiness 721.65 ms,
internal readable/controls ~472 ms; Christie outer 126.87 ms. Do not infer regression
or speedup from this one uncontrolled observation. Cache/renderer mechanisms alone
do not establish the full opening budget; keep APP-20261008-07 incomplete.

### Compatible binary fulltext cache — native verification

The durable primary is binary plist; existing durable/legacy JSON remains readable
and is retained byte-for-byte during successful migration. Corrupt primary entries
fall back to valid legacy content. Scoped eviction and quota pruning recognize both
formats, preserve unrelated audio and normalize book IDs consistently. No Rust or
Flutter contract changes. Native macOS cache/window set: 13 passed, zero skips.
Physical iPhone focused cache/renderer/UIKit set `E28AEFD2-00D3-4336-B79F-DD9AC2ACC6F4`:
17 passed, zero failures/skips; 42.80 s total, 28.04 s build, 11.17 s tests.
This proves cache compatibility, not the reader readiness budget. Same-input two-host
sample remains 355 ms for LOTR; the separate pending renderer optimization sample
is 343 ms. The 200 ms acceptance stays red and unchanged.

### Prepared chapter restoration — integrated native behavior

Both Apple readers now use a shared prepared renderer: full chapter/input/settings,
font directory, platform/OS and locale/language signature; secure attributed-text
restoration on MainActor; bounded atomic IO on the storage actor. Memory caches
immutable archive bytes rather than sharing mutable nested attachment/paragraph
objects between views. Corrupt/unsupported/signature-mismatched entries retain the
normal HTML fallback. Valid memory hits remain synchronous; pending disk restore
shows the existing loading cover and fences stale book/load generations. Geometry,
image handling, progress restoration and plain-text fallback are unchanged.

Envelope v2 validates archive SHA256 as well as input signature. Final macOS set:
17 passed, zero skips (`21-27-36` xcresult). Physical iOS set: 17 passed, zero skips
in `CAB5B9A6-A73C-4299-9E4D-3C3EF9A7451D` (9.31 s total, no rebuild).
Actual UIKit window also passed in `2898D60B-28A6-49E6-8465-9442DD25EEA9`:
prepared marker attributes and text survive on the real surface, content/controls
become ready, loading ends. The unit window explicitly performs its layout passes.
AppKit window tests prove prepared consumption and settings invalidation.

iOS's original equality failure exposed CG-backed fixed UIColor representation
changing on archive decode. Canonical fixed sRGB UIColor values now preserve full
equality; adaptive colors remain adaptive. No private paragraph API or weakened
fidelity assertion was used. One helper compilation initially lacked explicit self
and one SDK color type-ID spelling needed correction before the passing runs.

Two-host measurement with prepared rendering remains over budget: LOTR 439.05 ms
(journey controls 355.90 ms), Christie 132.10 ms. Evidence:
`reader-relaunch-353E8583-ECE5-49E7-9B93-0F7B7A9BF19B`; prepare passed, verify
failed the unchanged 200 ms assertion. This is a verified restoration slice, not
completion of the relaunch/performance goal. Raw full-book decoding remains costly.

### Prepared archive persistence — native storage boundary

Added the shared Apple actor `PreparedChapterArchiveStore`: immutable opaque
archive bytes, versioned binary envelope bound to book/chapter/signature,
SHA256 filenames, 8 MiB bounded file reads/writes and 64 MiB default total budget.
Budget rejection preserves earlier entries rather than evicting anything. Root/
target symlinks and special files are rejected; replacement is atomic and removal
targets exactly one owned book/chapter entry. Native archive creation/decoding
remains the caller's MainActor responsibility; no UI integration yet.

Nine native macOS tests passed, zero skips in `20-34-11` xcresult: reopened
durability, scoped removal, mismatches/schema/corruption, size/budget preservation,
symlink protection, invalid keys before directory creation and off-main inspection.
Physical iOS attempt stopped at locked readiness with no build/test. Fixtures
were isolated and removed; no books/models/downloads were targeted. This verifies
storage mechanics on macOS, not native iOS behavior or the 200 ms reader budget.

### Prepared attributed chapter — measured fidelity-preserving mechanism

Native opt-in test passed once with zero skips in
`reader-relaunch-39737E0E-1C15-4C50-9581-006E94EEEB92/attributed.xcresult`.
Same hash-checked sources, native chapter positions LOTR 8 / Christie 6; no
synthesis, cache writes or replacement of user data. Secure NSAttributedString
archiving/restoration preserved complete text and attributes by equality in all
three decodes per chapter. Initial compilation referenced a private safe-subscript
helper; replaced with an explicit index guard before the passing run.

LOTR HTML render 594.02 ms, archive decode 0.40–0.65 ms, archive 11,702 bytes.
Christie 16.16 ms, decode 0.38–0.55 ms, 17,194 bytes. These are same-process
Debug mechanism measurements, not across-relaunch reader performance. They
justify investigating durable prepared rendering rather than losing EPUB styling.
Production integration must invalidate changed settings/source/chapter, survive
corrupt/missing data safely, preserve attachments and keep IO off the main thread.

### Reader codec experiment — no production migration

`PreparedReaderCodecBenchmarkTests` compares actual typed payload decoding for
the same hash-checked EPUBs and asserts canonical JSON equality after each
JSON/plist roundtrip, including text, HTML, CSS and resources. Three observations
per codec/book; no synthesis or user cache writes. Final native test passed once,
zero skips in `reader-relaunch-3071CE3E-E1C4-4571-9172-948B12E9C8B1/codec.xcresult`.

Initial experiment (`reader-relaunch-A03CCD77-2B7C-43B7-B874-7897EEDEF06D`):
LOTR JSON decode 212.8–214.6 ms, binary 104.2–117.9 ms, sizes 25,090,570 versus
26,535,196 bytes. Christie JSON 14.4–15.2 ms, binary 11.5–12.2 ms; sizes
1,161,728 versus 2,051,479 bytes. These are Debug in-memory decode observations,
not full reader readiness or a production speedup. Binary is faster but larger
and does not eliminate the separately measured 537 ms HTML render. Keep the
current durable format until a complete, compatible readiness fix is verified.

### Prepared disk reader IO — verified narrow correction

macOS now skips redundant JSON encoding, atomic rewrite and cache inventory when
opening an already validated durable payload. Cold parsing still persists normally.
One actual native window regression passed, zero skips (`20-20-19` macOS xcresult):
disk cache supplies readable content/controls without resolving the unavailable
fixture source; original cache bytes and modification date remain unchanged.
The first fixture attempt used an empty bookmark and was pruned before opening;
fixed to a nonempty unresolved bookmark and an explicit loaded-index assertion.

The separate two-host relaunch measurement remains red: LOTR 2446 ms before,
985 ms in one candidate observation, still above 200 ms; Christie initially167 ms.
Focused timing identified LOTR read/decode 241 ms, HTML render 537 ms and TextKit
fit 1.6 ms. Temporary probes removed. This slice repairs redundant interaction-
thread IO; it does not establish relaunch budget completion or general speedup.

### Physical conversion comparison — candidate completed

Run `699FF2AE-0A79-406A-889C-FEF3EF01110F`: one benchmark passed, zero skips,
four exact requested chapters with playable MP3s. Source hashes/ranges and character
counts match baseline (112357/5778). Build reused; fresh jobs, no audio reuse.
Total 451.39 s; synthesis 438.48 s, test interval 444.83 s, verification 0.052 s
(overlapping intervals, not additive). Temporary staging cleanup was verified.

LOTR synthesis 310.397→432.123 s (+39.2%); Christie 6.339→6.353 s. Candidate
first published chapter callback 206.256/3.197 s, not acoustic playback. Footprint
point samples before→after synthesis: LOTR 70.81→57.60 MiB, Christie 57.77→46.24
MiB; Mach calls succeeded. These are not peak measurements or before/after-code
memory comparisons: baseline did not record delivery/footprint fields. Snapshot
provider/voice metadata remain null; telemetry identifies Edge, not a verified
matching voice/configuration. Parsed-text cache reuse remains unmeasured.

Candidate LOTR's initial 4095-character call took 14.47 s versus baseline's early
4092-character call taking 2.53 s. Candidate adaptation changed 4096/2 to 2048/1;
both selected chapters finished with no recorded retry/throttle events. This is
evidence of a slower observed sample and active adaptation, not proof that policy
caused the slowdown. Controlled Rust throughput investigation is routed to Arch
as APP-20261008-06. Do not declare performance resolved or synthesize larger ranges.

### Current acceptance checkpoint — 2026-10-08

Historical slice limits below describe their original verification time, not the
current task status. Physical runs `0132B263-6FB2-49B1-A195-9627078459AE`
(two tests) and `B882C802-84BE-4447-A0BD-23387F54BFF1` (35 playback tests)
passed with zero skips. Replacement-player session deactivation did not reproduce.
The same seven-class sequence now passed physically in
`D379076E-DD02-49A1-9DA3-BAA4C728648F`: 112 passed, zero failures, one skip
(`AudioPlayerObservationPrivacyTests/testOptInExistingChapterPlaybackLatencyAndMemory`,
requires explicit benchmark inputs). No rebuild; 54.64 s total, 51.92 s tests.
Earlier playback failures did not recur; their root cause is not established.
Lifecycle termination passed one isolated native macOS test; three physical iOS
tests passed in `E06BBEA9-291E-41F8-A2B8-8BBE5D3890E9`, zero skips. The real
callbacks flush queued isolated writes; expiration's generation-check method is
invoked directly, not by OS timeout. Physical conversion comparison remains pending.
This Mac runs only Apple work; Rust/Flutter validation belongs to Arch.
Conversion measurement instrumentation passed three native report/delivery tests
and one real Mach footprint capture test (macOS xcresults `19-28-01`/`19-28-53`,
zero skips). Additive report fields distinguish callback delivery from acoustic
playback and two footprint samples from peak memory. This is harness verification,
not measured synthesis improvement; the original device baseline lacks these fields.
After explicit retry, preflight `F7484961-F505-48EC-9245-237ECACF5D40` reported
ready and the lifecycle run above completed. The earlier locked report is historical.

### Slice 1 — durable import safety

Implemented: copy into an exclusively reserved same-volume staging directory;
replace only after the copy succeeds; same-file reimport is a no-op; cleanup
targets only that staging directory. No existing book is removed before copy.

Red: physical iPhone run `49ED0837-4B37-4DBF-9ADB-E904C77CA953` failed the
new preservation regression: the prior `Book.epub` was missing after simulated
copy failure (Cocoa 260). Final green:
`EAF9072B-CF91-43BE-A74D-D6AE92C9EE41`, four focused native tests passed,
zero failures/skips, 22.93 s total (13.11 s incremental build, 7.16 s tests).
Tests cover partial-copy and final-replacement failures, source/previous bytes,
staging cleanup, self-reimport, successful replacement with an old bookmark,
and the existing original-removal survival case. Only disposable fixtures were
created and removed; no user books/models/downloads were targeted.

Review against base `0d3a8229`, this plan and coding standards: the original
delete-before-copy cause is removed; two-axis inspection and specialist QA
requested replacement/bookmark and partial-copy evidence, which now passes.
An initial attempt to override the Swift replacement convenience did not compile;
the regression uses the corresponding overridable Foundation method instead.
`git diff --check` passed. No Mac UI or crash/power-loss durability claim is made.

Item 1 is verified on the physical iPhone. Items 2–7 remain pending.

### Slice 2 — chapter selection (in progress)

The existing form parser has been extracted without changing its behavior so
the exact production boundary is reachable by native tests. A regression now
requires rejection of malformed/reversed/overflowing selections, single-chapter
support and explicit empty-field whole-book selection. The first test attempt
`EB930396-C4D2-46D6-AB40-3BD390C6DFBF` stopped at locked-device readiness;
it did not compile or execute the regression. No parser fix or completion is
claimed yet. Broader Swift/FFI sentinel consistency remains part of this item.

Rust FFI boundary: the new regression reproduced acceptance of invalid
`-2..-1` as whole-book selection. Validation now rejects mixed/invalid negative
sentinels, reversed and out-of-bounds indices before allocation or output
directory creation in both existing conversion ABIs. Explicit `-1,-1` whole-book
and legacy nonnegative-start / `-1` to-end selection remain supported. A huge
end bound is rejected before allocating positional selectors.
`cargo test -p converter-ffi --lib --jobs 1` through mise and the native heavy
lease passed 12 tests, zero failures, in 0.01 s (6.29 s incremental compilation
after the cold dependency rebuild). Two public ABI regressions verify early
rejection without touching their output fixture; a regular-file destination
prevents any network synthesis even if that validation regresses.

Review: the Rust-only guard is verified on the host. C ABI signatures are
unchanged and successful explicit selection semantics are retained. Device
FFI embedding, form behavior and Swift to-end range reconciliation remain
pending; item 2 is not complete from this host evidence alone.
Specialist QA found no blocking Rust guard issue and requested a multi-chapter
fixture. The final 12-test run adds a three-chapter EPUB, verifies `1..2` and
`1..-1`, and rejects `1..0` with a valid start. Final compilation was 3.99 s;
evidence is `.reports/mobile-audio/quality-ffi-selection.log`. Rustfmt and
working/staged whitespace checks pass. Only the guard and this evidence are
included in its commit; native-form and adaptive-TTS changes remain separate.

Independent Rust chunk-adaptation work may proceed while native readiness is
blocked; ownership excludes the main agent's Swift files and no online synthesis
is authorized beyond the prescribed comparison samples.

### Slice 3a — reject unsupported provider configuration

Red: the core selector accepted requested `coqui` as Edge in
`unsupported_engine_configuration_never_silently_selects_edge` (0.00 s test).
It now returns an explicit `UnsupportedEngine` error for unsupported requested
or configured values instead of silently changing providers. Edge, Piper,
case/whitespace normalization and existing auto-to-Edge behavior are preserved.
This is only the core guard; UI/FFI options forwarding, runtime/model readiness,
flags and manual-conversion playback intent are still pending (item 3 partial).

Final serialized verification through mise: 70 core library tests, seven
pending-adaptation integration tests, and 12 FFI tests passed. Evidence:
`.reports/mobile-audio/quality-core-guards-and-adaptation.log`. No model download,
external TTS request or user-artifact mutation was involved.

### Slice 5a — dynamic pending chunks (host verified)

Pending fragments are selected after acquiring current capacity, using the
latest size limit. Retry fallback subfragments also honor subsequent reductions
and make strict recursive progress. Feedback is published before permits are
released, preventing waiters from seeing capacity before the pressure update.
Blank fragments are consumed without speech requests or audio indices; spoken
content, UTF-8 and audio order are retained. Chunk totals in telemetry are now
estimates while adaptation is active, not a fixed progress denominator.

Controlled local protocol regressions reproduced stale chunks after a size
reduction, stale retry subfragments after repeated 429s, and feedback after permit
release. Seven integration tests now cover those cases, whitespace-only request
avoidance, capacity growth/out-of-order completion, retry recovery and dropping
an active synthesis. Existing protocol tests also pass in the 70-test core suite.

Specialist final QA found no blocking issue; additional shared-controller shrink
and cancellation-during-cooldown stress coverage is not yet performed. This
verifies dispatch behavior, not full native cancellation or a speedup. Physical
FFI rebuild/embedding and exact-book before/after measurements remain required
for item 5 and all latency/memory acceptance gates.

### Slice 6a — bounded, asynchronous conversion-history reads

The Mac history controller now calls an asynchronous Foundation reader rather
than reading/ splitting the entire log on the main thread. The reader scans
16 KiB blocks backwards, selects the latest nonempty records, and enforces a
1 MiB byte budget. Partial leading records are discarded before UTF-8 JSON
decoding; malformed or unfinished records do not discard valid recent rows.
Cancellation is checked before IO, between reads and around decode. Refreshes
cancel prior work and discard results from stale generations; UI updates remain
on MainActor. A localized read-limit message distinguishes oversized history.

The lightweight `apple:foundation:test` task compiles the actual production
reader and DTO alongside native XCTest, without an app, Simulator or device.
Its SwiftPM scratch directory is nested inside the single `.build` tree and
the task holds the same native heavy-job lease. Seven tests passed, including
IO outside main, cancellation before opening, UTF-8/CRLF, oversized records,
zero-read limits and trailing blank-line compatibility. Specialist QA caught
the initial LF-only counting regression; its new native test failed before
counting nonempty records and passed after correction.

Controlled local measurement, identical synthetic 10,000-record content:
8,407,780 bytes / 2,628.59 ms before versus 98,304 bytes / 6.94 ms after, with
the same latest 100 records. Logs: `.reports/mobile-audio/history-before.log`
and `history-final.log`. These are single Debug service observations, not a
production-app speedup ratio or resident-memory measurement.
The four real Mac controller/reader/model/localization files also passed
`swiftc -typecheck -swift-version 5 -strict-concurrency=complete` for macOS 12.
Working/staged diff checks passed. No UI process was launched or user log changed.

Limits: full AppKit screen responsiveness/reload integration is not yet exercised;
the controller retains its legacy-compatible local log source (a native-history
producer was not added). Batch import, audio persistence and whole-app
latency/memory gates remain pending. This slice does not complete items 6–7.

### Slice 2b — fail-closed form chapter selection

The form uses the shared production `ConversionChapterSelection` parser, also
compiled unchanged by the native Foundation test target. Only an empty trimmed
field selects `(-1,-1)` whole-book conversion; a single nonnegative ASCII Int32
selects exactly itself, and an inclusive ordered range preserves its indices.
Malformed, empty-component, negative, overflowing and extra-component inputs
throw instead of being compacted or falling back to whole-book selection.
The view model localizes that error before security-scoped access or conversion.

Red: three native parser tests produced 13 failed assertions, reproducing invalid
inputs and single indices silently becoming whole-book selection. Final green:
`mise run apple:foundation:test` passed all 10 tests (three parser, seven history),
including Int32 maximum, overflow on either endpoint, same-index ranges, plus
signs, Unicode digits and decimal values. Logs are
`.reports/mobile-audio/chapter-selection-red.log` and `chapter-selection-green.log`.
Specialist review found no blocker; requested edge coverage was added. Working
and staged whitespace checks passed; literals/locales were preserved.

This verifies the form's production parsing boundary on the native host, not its
full UIKit integration. The matching view-model XCTest is checked in but has not
run since the locked-device preflight. Swift coordinator / FFI start-to-end
sentinel consistency and native embedding remain pending, so item 2 stays partial.

### Slice 2c — reconcile raw bounds with book metadata

The coordinator now validates raw sentinel/range syntax before opening metadata,
then resolves a nonnegative start / `-1` end to the actual last chapter. It no
longer substitutes a single chapter for reversed or to-end requests. Invalid
sentinels, reversal, empty scoped books and out-of-book indices are rejected
before output creation; the resolved inclusive range drives post-manifest counts.

Red: the extracted production resolution behavior failed eight native assertions,
including `1..-1` resolving to `1..1` for a three-chapter book. Final green:
`apple:foundation:test` passed 12 tests (five chapter-selection, seven history).
Evidence: `.reports/mobile-audio/chapter-bounds-red.log` / `chapter-bounds-green.log`.
The actual coordinator, adapter, snapshot, parser and localization files passed
strict-concurrency Swift typechecking for macOS 12. Specialist review found no
blocking bounds issue and confirmed existing start-to-end callers remain compatible.
Whitespace/diff checks passed. No user book was synthesized or modified.

Limits: host resolver tests and typechecking are not a full native coordinator
conversion run. Manifest validation still checks count, not chapter identity;
device integration and final artifact embedding remain acceptance gates. Item 2
is therefore not closed merely from these host checks.

### Slice 3b — versioned configuration and safe callback lifetime

Added the optional `converter_session_convert_job_options_json_v1` ABI and
`converter_conversion_options_validate_json_v1`. Version 1 JSON requires
`schema_version`, rejects unknown fields and unsupported engines, and forwards
engine/voice/language into the real worker request. Existing conversion symbols
retain their signatures and Edge defaults. Explicit Swift options require both
new symbols and never fall back to a legacy call that would ignore them.
The coordinator validates with Rust before metadata access or output reservation.

Flags `clear_cache`, `force_reprocess` and `max_performance` are represented and
reject true explicitly in this tracer; their effective behavior is not implemented
or waived. Runtime/model readiness and frontend choices remain pending.

Adversarial QA exposed borrowed Swift callback context surviving a worker timeout.
The common callback ABI now owns a synchronous shutdown scope: foreign callbacks
run only while its mutex gate is active; scope drop drains a running call and
blocks late worker clones before the Swift caller can release its context.
Callbacks must not reenter the same gate or wait for this ABI to return. Late
Rust log events outside the foreign gate may still occur; full worker cancellation
is not established by this lifetime fix.

Red evidence: unsupported Coqui options reached the output boundary before
validation; three isolated callback-scope tests failed before closure/drain logic.
Final integrated Rust FFI suite: 18 passed. Actual host Swift/FFI XCTest:
`apple:foundation:ffi:test` builds the real dylib and passes 16 tests, zero skips,
including schema encoding, both legacy and configured calls, missing-capability
rejection and coordinator validation without book/output access. Synthetic EPUB
and blocked-output fixtures prevent online synthesis even if validation regresses.
Logs: `.reports/mobile-audio/ffi-options-callbacks-final.log` and
`swift-rust-options-interop-final.log`. The actual Swift coordinator, adapter,
options, selection, snapshot and localization sources also passed strict typecheck.
Specialist final review found no blocking issue; whitespace checks passed.

This is host runtime/interop evidence, not a physical-iPhone packaging or full
conversion run. The view-model form still needs options forwarding and removal
of manual autoplay. Item 3 remains partial; all other open acceptance gates remain.

### Slice 3c — manual form configuration and playback isolation

The actual form now forwards literal engine/voice/language and all three flags
through the configured Rust coordinator. Manual success records the job without
setting a player snapshot, starting playback or resuming an existing session.
The injectable executor defaults to the real embedded coordinator.

Native macOS app XCTest: six passed, zero failed/skipped in
`Test-EpubToMp3Mac-2026.10.08_15-20-48--0300.xcresult` (12.2 seconds wallclock).
Coverage includes exact options/range forwarding, an existing paused snapshot
remaining unchanged, and real bundled Swift/Rust rejection of Coqui before
opening a nonexistent book. Earlier failing tests reproduced missing options
and replacement of the playback snapshot. Final diff and specialist review found
no blocking issue. Reused incremental native build and the completed Rust dylib.

Limits: active audible playback was not exercised; true flag semantics and model
readiness are still pending, as is device conversion/performance verification.

### Chapter scope — exact output identity

Scoped coordinator success now requires the requested job ID and exact ordered
`sourceIndex` list, not just an equal chapter count. Missing identities,
duplicates, reversed/substituted selections and excess/missing chapters fail.
`apple:foundation:test` with the existing release dylib/fixture environment passed
17 native tests, zero failures/skips (4.90 seconds incremental compile; 0.475
seconds tests). The added regression exercises the production result validator;
the scoped conversion calls this validator before publishing success. No synthesis
or Rust rebuild. Physical-device integration remains pending.

### Slice 4 — chapter-relative segment navigation

Segment seek resolves real AVFoundation durations over a contiguous ordinal
prefix, rebuilds the bounded queue at the selected segment/local time and restores
the chapter clock. Next/previous rebuild from retained files instead of consuming
the live queue. Missing segments/chapters remain pending; pause, replacement and
stop fence asynchronous duration loading and seek callbacks.

Native macOS app XCTest: 42 passed, zero failures/skips, including 13 new
regressions. Evidence: `Test-EpubToMp3Mac-2026.10.08_15-27-08--0300.xcresult`;
82.3 seconds total, 37.0 seconds test interval. Real waveform fixtures verify
segment-local and chapter-relative positions, backlog navigation, paused/playing
intent, sparse arrivals, exact boundaries and cancellation. First compilation
failed on an unused binding introduced by extraction; removed before the green
run. Review covered ordinal gaps and pause changes across suspension. Diff checks
passed. No book synthesis, Simulator, Python or user-data cleanup.

This proves native player behavior on macOS, not physical-iPhone latency/memory.
Segment persistence IO and final performance/device gates remain open.

### Slice 3d — effective per-request execution flags

True flags now reach the worker: selected derived text is refreshed atomically,
selected audio is regenerated through validated staging, and maximum performance
permits parallel selected chapters within existing configured/platform caps.
Staging ownership survives late synthesis threads; failures preserve prior audio.
Books, models, listening downloads and unselected chapters are untouched.

Focused Rust passes: 10 worker tests, six cache tests, one actual-worker isolated
synthetic-Piper integration and 19 FFI tests, all passed. Native
`apple:foundation:ffi:test`: 17 passed, zero failures/skips with the freshly built
debug dylib. True flags reach a blocked output boundary rather than rejecting or
being silently ignored. Integration verifies forced synthesis versus resume,
exact selected source identity and preserved artifacts; adversarial tests cover
symlinks, partial/invalid audio and late-writer staging lifetime. Rustfmt and diff
checks passed. No user book synthesis, release rebuild or model download.

Host execution/interop is verified; final Apple artifact embedding, offline
model-path/readiness and physical performance remain pending. This is not a
measured speedup or a guarantee of full worker cancellation.

### Slice 6a — asynchronous bounded library import

Picker, incoming-URL, Documents and shared-inbox paths now await serial worker
preparation (scope/hash/archive/copy/metadata/cover). Only immutable resource
references and prepared values cross that boundary. One main-actor publication
and persistence occur per batch; edits made during preparation survive, removed
books are not resurrected, and failed reimports preserve previous bytes/index.
Documents keep sources; inbox removes only successfully imported payloads.

Shared native macOS verification: 60 tests passed, zero failures/skips across
LibraryStore, SharedContainerImporter, AudioPlayerEnqueueSegment and
JobDetailViewModelStreaming. Evidence:
`Test-EpubToMp3Mac-2026.10.08_15-40-15--0300.xcresult` (68.6 seconds total;
3.684 seconds test interval). Library regressions exercise actual Mac controller,
worker copy thread, partial batch failure, one persistence, concurrent edits and
removal, failed replacement and both importer callers. Initial compilation found
Foundation Sendable captures/type inference; fixed with a narrow immutable IO
resource carrier, without marking the store Sendable or relaxing compiler checks.
Final diff review and whitespace checks passed. No user-data cleanup/synthesis.

Limits: index JSON encoding/loading still synchronous; iOS-only UI branches and
physical-device responsiveness/performance remain pending. Synchronous legacy
import remains compatible and is not claimed to be nonblocking.

### Slice 6b — segment audio persistence off main

Production streaming callbacks now await a per-player serial file writer before
acknowledging a chunk. Playback publishes only after writing finishes; capacity,
ordering, duplicate preservation and cancellation remain explicit. Session
generation fences reject stale completions; old owned temporary directories are
cleaned on the writer after cancellation. The disabled legacy coordinator is
not a product caller and was left unchanged.

The same 60-test native run above covers five new writer regressions plus the
existing enqueue and real view-model callback tests: off-main blocked write with
responsive main actor, ordered publication, stale-session cleanup, write failure,
duplicate preservation and cancelled capacity waiters. Diff/ownership review
passed. Synchronous enqueue remains only for compatibility/tests; production
iOS/macOS streaming sinks await the async API.

Limits: successful file writing is not an fsync/power-loss guarantee. Physical
iPhone verification and latency/memory comparisons are still pending.

### Slice 3e — explicit model readiness and request-local paths

Piper options require absolute `models_root`, single-component `model_id`, and
relative `model_path`/`model_config_path`. Rust resolves the installed namespace,
rejects missing/unreadable files and escapes, initializes the actual runtime and
checks readiness before book/output access. Edge/auto reject model fields.
Prepared requests pin paths/runtime through the worker thread; init+synthesis
share a transaction lock rather than process environment model selection.
Legacy calls without explicit options retain compatibility.

Focused verification: five Piper unit tests, two isolated actual-worker tests,
21 FFI tests and 19 native Swift/real-dylib tests passed, zero failures/skips.
Regressions cover failed initialization/unready runtime, unsafe paths, concurrent
model requests, literal Swift encoding and early coordinator rejection without
book/output access. Worker fixture deliberately supplies an incompatible model
environment to prove request-local routing. Rustfmt/diff and two-axis owned diff
review passed. No model download, optional runtime dependency build or synthesis
of user books.

Limits: the feature-enabled native Piper adapter is not compiled/exercised in
this host pass; shipping Apple builds without that runtime fail clearly rather
than pretending installed files enable inference. Frontend installed-model
selection and final physical-device embedding remain pending.

### Slice 6c — asynchronous library index persistence

JSON encoding and UserDefaults writes now use ordered immutable snapshots on a
serial worker. Async flush reports the last committed snapshot/error without
blocking UI; synchronous flush preserves the legacy import/reload contract.
Async imports flush before returning success so inbox callers retain sources on
index failure. Explicit flush barriers make integration reload tests deterministic.

Native macOS XCTest: 45 passed, zero failures/skips; evidence
`Test-EpubToMp3Mac-2026.10.08_15-52-17--0300.xcresult` (68.2 seconds total,
2.397 seconds test interval). Tests cover blocked encoder/main responsiveness,
encode/write threads, ordered/latest snapshots, failed encode preserving prior
index, recovery, source preservation, batch callers and persistence across reload.
Review and diff checks passed. No user-data cleanup or book synthesis.

Initial library load is still synchronous. Lifecycle flush hooks are a separate
pending Apple validation change; index-write completion is not fsync/power-loss
durability. Performance and physical-iPhone gates remain open.

### Native fixture and portable FFI regression

Physical run `364BEC13-3B6B-49E7-B9FA-C1D598DF9055` executed 109 tests:
98 passed, 11 failed, zero skipped. One FFI failure was the metadata-only EPUB
fixture's empty spine. Follow-up `65846453-6579-4B64-A7D7-F00A4029CEC8`
exposed its chapter fixture's unresolved cover reference. The chapter OPF now
matches `OEBPS/images/cover.png`. Both host and app interop tests use this actual
chapter fixture and real adapters; app tests no longer need host-only dylib paths.

Final `apple:foundation:test` with the existing debug dylib passed 20 tests,
zero failures/skips (2.33 seconds incremental compile; 0.111 seconds XCTest).
The new parser regression verifies readable spine/title; opening also validates
the referenced cover. The same fixture exercises all execution flags against a
blocked output, without network synthesis. Diff review/checks passed.

Physical playback failures remain unresolved. A two-instance session-release
regression is prepared and typechecks for iOS but has not run on the phone.
Lifecycle hooks and actual latency/memory measurements remain uncommitted and
unverified; no goal completion or performance improvement is claimed.

### Existing-audio playback measurement — macOS candidate only

One actual native XCTest passed with zero skips using the requested EPUB hashes
and exactly LOTR source indices 8–9 / Christie 6–7. It reused the four validated
MP3s; no source, model, download or audio was replaced and no synthesis occurred.
Evidence: `.reports/mobile-audio/cached-playback-candidate.b2TUaH/tests.xcresult`
and its exported `native-existing-audio-benchmark` JSON attachment.

Observed first progressing audio: LOTR 620.97 ms, Christie 343.86 ms. Seek:
38.17 / 42.10 ms; next chapter: 27.62 / 28.35 ms; previous: 23.44 / 26.04 ms.
Point-sampled physical footprint ranged from 10.18 to 14.21 MiB, RSS from 35.71
to 43.12 MiB, with successful native task_info queries. Samples are not peak
memory; AVPlayer progress is not an acoustic latency measurement. Debug macOS
results cannot stand in for iPhone behavior or cold conversion latency.

The initial run skipped because xcodebuild did not forward the process environment.
The final run reused build-for-testing products with explicit input environment
in an isolated version-1 Mac xctestrun, and executed exactly one test. Inputs are
literal/hash-checked and reports retain executable identity and journeys.
Baseline executable/report is unavailable, so comparison remains explicitly
unmeasured. Book-opening and physical-phone measurements are still pending.

### Baseline provenance audit and Debug payload identity

A source archive of `0d3a8229` was built with the saved old macOS Rust artifact
and identical measurement test/inputs. Its cached-playback test passed once,
zero skips: `.reports/mobile-audio/cached-playback-baseline.Txt20v/tests.xcresult`.
Production baseline source was not patched; instrumentation was copied only to
the test file. The current app build was restored afterward in the shared cache.

Report comparison found identical launcher hashes despite different production
sources: modern Debug app code lives in `EpubToMp3.debug.dylib`, not the launcher.
Reports now also identify that payload (or the executable for non-split builds).
The native identity/scope regression passed once, zero skips, in
`Test-EpubToMp3Mac-2026.10.08_18-45-26--0300.xcresult`.
The older measurement reports lack this payload identity, so a strict paired
comparison remains unproven and needs refreshed measurements. No speedup claim.

### Matched macOS cached-playback before/after sample

Refreshed baseline/current measurements each executed one test, zero failures or
skips. EPUB/audio hashes, selected indices and inputs match; actual app-code
hashes differ (`eb1ad816…` before, `4a17bd31…` after). Evidence directories:
`.reports/mobile-audio/cached-playback-paired-baseline.NeVQpv` and
`cached-playback-paired-candidate.KOIyxO`, including permanent XCTest attachments.

LOTR before→after: first progressing audio 497.91→498.21 ms, seek
39.34→44.36 ms, next 30.66→45.53 ms, previous 28.93→30.85 ms.
Christie: 340.27→346.72 ms, seek 51.45→41.86 ms, next 44.35→46.61 ms,
previous 27.61→28.33 ms. Largest sampled footprints: 14.28→14.22 MiB.

This single Debug/macOS pair shows mixed small timing changes, not a demonstrated
general speedup or causal regression. Audio is cached, progress is not acoustic,
memory is point-sampled, and this does not cover segment-mode or conversion speed.
No synthesis or user-data cleanup; current app products were restored in the
single shared build cache after the baseline run. Physical playback failures,
iPhone measurements, book-open budgets and conversion comparison remain open.

### Native reader opening — measured macOS warm budget

The existing book-open XCTest now also opens a real AppKit reader window, using
the same literal/hash-checked books and test-only library/progress/cache identities.
Production reader behavior is unchanged; native-reader-regression directed the
real-surface verification rather than a parser-only latency proxy. No conversion.

Initial measurement: LOTR prepared-cache cold 5124.20 ms, process warm 51.15 ms;
Christie 513.01 / 93.46 ms. With the permanent 200 ms warm-open assertion, a
second executed test passed (zero skips): LOTR 3975.75 / 47.42 ms, Christie
460.84 / 91.89 ms. Evidence:
`.reports/mobile-audio/native-book-open-budget.AYCSN7/tests.xcresult` and the
permanent `native-existing-epub-open-benchmark` attachment. Ready milestones show
both readable content and usable controls; memory is only point-sampled.

Process-warm Mac readiness meets the budget in these runs. This is not an
across-relaunch result, iPhone evidence, clipping/pagination verification, or a
before/after reader comparison. Cold parsing remains seconds for LOTR and needs
separate profiling if optimized. Physical playback failures and bounded device
conversion/performance verification are still open.

## Provider-neutral chapter snapshots — 2026-10-09

Scope: remove the hard-coded Edge engine from the shared Apple chapter-completion
snapshot. The Rust chapter event carries no resolved engine, voice or language;
represent those as unknown rather than claiming a provider. No ABI, provider
selection, playback queue, artifact, reader geometry or Flutter changes.

`RustConversionCoordinatorTests/testValidatedChapterEventMapsToPlayableLocalSnapshot`
decodes the actual event contract and invokes the production snapshot mapper.
Executed through `mise run apple:chapter-callback:test` with that single test.
Red evidence: `Test-EpubToMp3Mac-2026.10.09_06-59-48--0300.xcresult`, exactly
one failure (`XCTAssertNil failed: "edge"`). Green evidence:
`Test-EpubToMp3Mac-2026.10.09_07-00-49--0300.xcresult`, one passed, zero
failed/skipped. Both bundles are under `ios/EpubToMp3/.build/Logs/Test/`.
Simulator was stopped before serialized Mac checks; no synthesis or source-data
mutation. Reviewed the owned diff and whitespace. This proves shared Swift
mapping behavior, not iOS UI or Flutter parity. Resolved provider metadata through
the Rust ABI and the installed-model frontend selector remain pending.

## Failed inbox source preservation — 2026-10-09

Safety review found that the synchronous SharedContainerImporter.drain removed
source payloads even after LibraryStore import failure. The async production UI
caller already preserved failed sources; align the compatibility entry point.
Only successful durable imports now permit deleting their inbox source. Failed
expanded EPUB content remains available for repair/retry. No runtime routing,
model/download cleanup, IO scheduling or Flutter change.

Native red: `SharedContainerImporterTests/testDrainRejectsInvalidExpandedEpubDirectory`
failed the source-preservation assertion in
`Test-EpubToMp3Mac-2026.10.09_07-04-03--0300.xcresult`. Green sync checks:
failed-source byte preservation, missing source error, successful expanded EPUB
durable import/cleanup; three passed, zero failed/skipped in `07-05-01` bundle.
The initial selection also contained a nonexistent async test name; that test did
not execute. Corrected exact selection
`testAsyncInboxCallerPublishesDurableBookAndPreservesFailedSource` then passed
separately, one passed, zero failed/skipped in `07-05-56` bundle. All bundles
are under `ios/EpubToMp3/.build/Logs/Test/`; actual summary counts verified.
Executed `mise run apple:chapter-callback:test` with APPLE_NATIVE_TESTS filters.
Tests use owned temporary fixtures; original books, models/downloads preserved.
Owned diff reviewed; no claim of iOS UI, Flutter, or complete import-IO acceptance.

## Mac cold-reader persistence off MainActor — 2026-10-09

Scope: the actual Mac reader cold EPUB branch still called LocalFulltextCache.save
on MainActor, encoding/writing the full book and collecting rebuildable cache files.
Inject the existing save boundary for native observation, execute it in an awaited
utility detached task, then recheck cancellation/book/load generation before any
UI presentation. Preserve ordering: durable save completes before presentation and
chapter-projection preparation. Warm cached loads still skip this save entirely.
Best-effort cache writes already in flight may finish after a selection changes;
their completion cannot restore old UI. No renderer, typography, pagination,
chrome transition, TTS, download or shared Rust changes.

Native controller regression imports a unique chapter-bearing EPUB through
LibraryStore, forces the cold branch, schedules a MainActor heartbeat while the
writer blocks, invokes the real LocalFulltextCache.save and decodes the durable
binary payload independently. It verifies source bytes and no autoplay. Red:
`Test-EpubToMp3Mac-2026.10.09_07-09-30--0300.xcresult`, one failed test,
"Cold-open persistence must not block the UI thread". Green:
`Test-EpubToMp3Mac-2026.10.09_07-10-38--0300.xcresult`, five passed,
zero failed/skipped (cold writer plus four restoration/readiness regressions).
Added an adversarial selection-clear during the blocked write, verifying no stale
text/selection after completion: `07-12-07` bundle, one passed, zero failed/skipped.
Bundles are under `ios/EpubToMp3/.build/Logs/Test/`; summaries inspected.
Commands: `mise run apple:chapter-callback:test` with the class/single-method
APPLE_NATIVE_TESTS selections. Simulator remains stopped; heavy checks serialized.

Limits: native fixture controller evidence proves the caller's executor and stale
state behavior, not measured real-book speed or the 200 ms across-relaunch budget.
No seeded LOTR clipping/chrome gate or iOS UI run in this non-geometry IO slice;
those broader reader requirements remain open. Original books/models/downloads
unchanged. No broad cache purge; tests clean only their unique prepared-book entries.

## Relative segment controls and confirmed endpoints — 2026-10-09

Specialist audit exposed a caller gap: direct chapter-relative seek worked, but
skipForward/skipBackward used the current AVPlayerItem clock. Public command
regressions proved wrong identities: backward from 35 s by 15 stayed in segment 2;
forward from 5 s by 30 stayed in segment 0. Red: `07-16-58` Mac xcresult,
two failed. Relative segment commands now use the existing chapter seek resolver,
preserving intent and pending targets. Nonsegment skip behavior is retained.

First candidate failed three of four cases (`07-18-44`): status/duration KVO
overwrote the chapter clock with a single item's duration. Both sinks now preserve
segmentChapterDuration. Review caught another issue: a positive estimate is not
a confirmed endpoint. Only completed/finished metadata with a valid duration, or
a completed chapter's fully known contiguous retained durations, establishes its
end. Incomplete chapter targets are neither clamped to estimates nor advanced to
the next chapter. A confirmed final end clamps without phantom pending audio.

Six focused Mac cases passed (`07-23-38`), then the affected class passed all
38 executable Mac cases, zero failures/skips (`07-28-12`). Original endpoint
fixtures now explicitly declare completion and exact segment duration; receipt,
backlog-correlation and capacity tests use Next for their chapter-navigation intent.
No weakened identity/intent/journey assertions. Native review found no blocker
for this slice; late endpoint confirmation remains APP-20261009-34.
Mac bundles: `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_*.xcresult`.

Guarded incremental iOS build used the release embedded artifact; Simulator was
stopped during compilation. Xcode 16.4 executed the four new public-command cases
on iOS 16 SE: four passed, zero failed/skipped, result
`.reports/simulator-smoke-4747F161-AEEE-4AEC-A936-D4C4DF4C679E/tests.xcresult`.
Checks used apple:chapter-callback:test and ios:simulator:smoke:build/test with
explicit class/method filters. Actual AVPlayer items, chapter position, item-local
offset, duration, pause, missing-audio arrival and confirmed final boundary checked.
No synthesis, Python/Ruff, physical iPhone, Flutter or CI/PR monitoring. Original
books, models/downloads unchanged. UI button taps and real-book timing were not
measured. Item 4 remains open for late endpoint reconciliation and parity; the
full seven-item goal remains active.

Configuration audit separately confirms the frontend selector is still absent:
FFI fields exist, but the form and shared executor do not carry installed model
selection. Apple packaging tasks do not enable the optional Piper runtime. Model
metadata/catalog presence is not proof of a runnable installed model; do not
claim offline configuration complete or download/migrate models implicitly.

## Late confirmed segment endpoint — 2026-10-09

APP-20261009-34: a seek to 35 s on an incomplete final chapter remained pending
after its 15 s endpoint was confirmed by updateSnapshot. Native regression failed
"Navigation must finish against real media" (`07-38-25` Mac xcresult). The
equivalent final-file handoff already passed before this change (`07-36-09`);
its production path remains unchanged, rather than adding an unnecessary clamp.

The segment duration resolver now reconsults the live request and the requested
chapter's confirmed endpoint after loading durations. It updates the existing
position/endpoint permission before deciding to wait, preserving request ID,
journey and current pause/resume intent. Estimates still cannot clamp targets;
replacement/cancellation guards remain. No IO scheduling, provider, artifact or
reader geometry changes. Specialist read-only review found no blocker.

Mac initial four cases passed (`07-40-19`). Final tightened selection: five
passed, zero failed/skipped (`07-42-41`): late segment confirmation, unchanged
file handoff, confirmation before duration-task execution with pause overriding
autoplay, unknown boundary and replacement seek. The first three assert real
AV time and published position, pause, no journey cancellation, pending removal
and exactly one seekTargetReached on the original journey. Mac bundles under
`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_*.xcresult`.

Guarded iOS incremental build/test on iOS 16 SE, Xcode 16.4 test controller:
three new cases passed, zero failed/skipped. Result:
`.reports/simulator-smoke-BFACF03A-8FCE-4923-8EE9-5F90C077C81E/tests.xcresult`.
Executed apple:chapter-callback:test and ios:simulator:smoke:build/test with
explicit method filters. Reused the embedded release Rust artifact; Simulator
stopped during compile, heavy work serialized. Original books/models/downloads
preserved; fixture-owned temporary audio only. No synthesis, Python/Ruff,
physical-device, Flutter, or CI/PR monitoring.

This proves the Apple pending-navigation boundary, not button-tap UI automation,
Flutter parity, real-book latency/memory or the 200 ms opening budget. The overall
goal and parity checkboxes remain open.

## Actual prepared-renderer overhead diagnostic — 2026-10-09

APP-20261009-36 extends the existing opt-in attributed chapter benchmark with
the actual public cached()/restore() paths, using fresh renderer memory for each
of three samples, a UUID-owned archive store, flushed writes, and complete native
attributed equality. Same hash-checked source books: LOTR native chapter ordinal
8 and Christie 6. No synthesis or production behavior change.

One native test passed, zero failed/skipped. Command:
`xcrun swift .reports/mobile-audio/run-reader-relaunch.swift attributed`.
Existing serialized lease held through incremental Mac build and execution;
Simulator stopped first. Result:
`.reports/mobile-audio/reader-relaunch-97E2EE78-26FC-4C48-A40E-C6D3C2C2C929/attributed.xcresult`.
Attachment: `9141F16D-BDF6-42E8-B717-0C115BB8C0C1.json` in its attachments directory.

| Book | Signature + empty memory lookup median | Prepared disk restore median | Raw keyed decode median |
| --- | --- | --- | --- |
| LOTR | 0.377 ms | 2.267 ms | 0.669 ms |
| Christie | 0.266 ms | 1.729 ms | 0.355 ms |

Prepared restore includes signature, envelope IO/validation, post-await signature
and keyed decode; do not add its constituent intervals. Raw archive sizes are
11702 / 17194 bytes, not envelope sizes. First HTML rendering was 2251.419 /
23.262 ms, one sample each; framework startup and order prevent a causal
comparison. These measurements do not account for complete catalog loading or
TextKit/view readiness, additional cached/render calls, process relaunch,
registered EPUB fonts or memory peak. Three same-process samples with OS caches
warm are not statistical evidence of a global improvement.

Specialist review found no fidelity/lifecycle blocker and identified those limits.
Signature work is too small in this measured path to explain the outstanding
363.818 ms LOTR relaunch observation. Production signature/cache format remains
unchanged; next profiling should target catalog/presentation rather than weaken
source/settings validation. Original books/models/downloads preserved; only the
owned temporary archive namespace was removed. The 200 ms/full goal remains open.

## Startup prewarm yields to actual reader load — 2026-10-09

APP-20261009-37: both Apple startup roots now use one MainActor-owned utility
Task. Both actual reader load entry points cancel it without waiting for drain.
Prewarm checks cancellation between its at-most-two books; cache reads check
before IO/decode and before retaining/migrating prepared content. Foreground
reading remains independent. No new deletion, cache format, geometry or provider
change. A synchronous read/decode already begun cannot be claimed interrupted,
and check-to-publication races are not a transactional cancellation guarantee.

Red native cases: canceled prewarm still read its second book (`08-21-06`),
and the actual Mac reader failed to cancel a blocked prewarm (`08-24-10`). Green:
13 LocalFulltextCacheTests passed (`08-25-11`), then the tightened pre-cancelled
read passed separately (`08-29-07`), all zero failures/skips. New tests check
reader readiness while the prewarm worker is blocked, future-read exclusion,
unaltered durable bytes and no memory publication from a pre-cancelled read.
Owned renderer/temp cache and saved user defaults are restored. A semaphore in
the asynchronous test body was replaced with AsyncStream to avoid a new Swift 6
warning; blocking simulation stays only in the synchronous injected IO callback.
Mac bundles under `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_*.xcresult`.

iOS 16 guarded build/test: two helper cases passed, the caller fixture failed
to observe stable-layout readiness (`simulator-smoke-4765C2F7-5C49-4D2A-8749-98A0EAA46CFC`).
After attaching the test window to its UIWindowScene and processing pending layout
passes, the same caller assertions passed separately, one passed/zero failed/skipped:
`.reports/simulator-smoke-55AFC995-6B0E-40A5-9E1A-B97A1751E6FB/tests.xcresult`.
No timeout expansion or production layout change. Evidence is two + one, not
a single three-case green bundle. Commands used focused apple:chapter-callback:test
and ios:simulator:smoke:build/test; Simulator stopped during heavy compilation.
Read-only specialist review found no correctness/data blocker.

Same-book/range two-host measurements used the unchanged strict 200 ms assertion
and `run-reader-relaunch.swift`: baseline `3EF920C4-54D7-4233-935D-4D68A436D07F`,
candidate `C5F1F42D-7FD3-4FD5-A690-4F6AF541CFBB`, under `.reports/mobile-audio/reader-relaunch-*`.
Both prepare phases passed; both verify phases executed one test and failed
LOTR's budget (zero skips), not a crash. Complete EPUB/audio input metadata and
hashes match; app-code hashes differ. LOTR 835.299 → 394.444 ms; Christie
158.751 → 161.847 ms. Point footprints: LOTR 52,842,496 → 50,352,128 bytes;
Christie 54,771,712 → 53,194,752 bytes, not memory peaks.
Attachments `571284A6-3403-4C73-9161-7BF8A95D6DD8.json` / `595A0172-49E4-42D2-BD71-F6C90E723515.json`.
One pair with uncontrolled startup/OS variance does not prove causal speedup.
The benchmark includes a new window, whereas the production root reuses a window;
their difference also contains setup/polling, not only window cost. No clock or
gate was moved to manufacture success. LOTR and broader performance acceptance
remain open. No synthesis or original books/models/download mutation; Flutter
parity and the broader seeded reader geometry gate were not run in this IO slice.
