# Progressive reading and narration session

## Scope and ownership

Implement on `feature/progressive-reading-session`, based on develop 0effe3a52f,
in an isolated worktree. The original `feature/embedded-mobile-audio` worktree
contains uncommitted dependencies, fixture and tests: preserve them verbatim.
Do not incorporate that work without an explicit, reviewable integration.
Reuse AudioPlayer as the sole native playback authority; keep conversion rules
in Rust and Apple transport integrations in Swift. Preserve all clients and data.

## Evidence and dependencies

Existing code already provides progressive chapter callbacks, SegmentBacklog,
ResumeStore, playback retention, paused shell rehydration and resource guards.
These are implementation findings, not new runtime acceptance evidence.
Proven gaps: cross-job snapshot acceptance and segment-queue preservation;
delayed AVFoundation callbacks without queue identity validation; manual
conversion autoplay; Rust completion emitted before durable terminal state.
The separate embedded-audio effort records a real iPhone blocker: external
ffprobe/ffmpeg invoked by audio.rs. Full progressive journey acceptance depends
on that work; do not declare this initiative complete while it remains blocked.

## Slices in dependency order

1. Protect native session isolation with XCTest, then gate snapshot and
   AVFoundation callbacks by active transport/job identity. Verify focused
   native tests on iPhone. No geometry changes.
2. Protect explicit manual conversion with XCTest, remove automatic playback
   handoff and verify playback remains an explicit command.
3. Protect Rust terminal ordering/cancellation with Rust tests, persist terminal
   state before notification. Run focused managed tests under heavy-job guard.
4. Recover audio cursor independently from reading cursor, reject stale shell
   rehydration, preserve stable chapter identity and existing marker format.
5. Audit artifact recovery/offline protection and progressive pending navigation;
   add missing regressions, verify native relaunch/player and Rust artifacts.
6. Integrate compatible embedded-audio fix only when available, verify signed
   iPhone runtime with at most two chapters; audit diff and commit/push verified
   slices. No CI/PR monitoring, merges or publication.

## Acceptance

Opening does not synthesize/play; Play requests available audio; progressive
queue and pending navigation honor intent; pause keeps cursor; manual conversion
never autoplays; stale sessions cannot mutate active state; recovery trusts real
files/jobs/player and never restores transient activity; offline retention
survives cleanup; terminal completion means persisted validated artifacts.
Native XCTest/real player evidence is required for Apple behavior, Rust tests
for job/artifact rules. Compilation/source contracts cannot fulfill device gates.

## Checkpoint

Discovery complete. Implementation and verification pending. Record exact
commands/results here after each slice. Roll back owned commits with git revert;
manifest/marker formats remain unchanged. Do not reset the original worktree.

### 2026-10-07 implementation checkpoint

Implemented code slices (Apple runtime acceptance remains pending):

- AudioPlayer still owns transport. ProgressiveNarrationSession, retained by
  that player, owns one Rust attachment, explicit job/book identity, first
  requested chapter gating, deduplicated Play and obsolete callback rejection.
  iPhone and macOS commands share it. Opening never calls its start command.
- Manual ConvertViewModel publishes a validated result without replacing or
  resuming transport. Its old source-inspection test was replaced by XCTest.
- Native callbacks validate transport generation/item identity. Pause clears
  pending first-audio autoplay. Legacy embedded audible retention is persisted
  through the existing artifact store rather than merely latched in memory.
- ResumeMarker adds optional sourceChapterIndex and stable lookup keys, preserving
  the v1 offset keys/read compatibility. Shell restores paused audio from the
  audio cursor, rejects stale async work, and never reads the reader cursor.
- RustAudioRecovery reads bare terminal manifests and incremental journals,
  merges identities, checks safe local paths, AVFoundation playability/duration,
  and only calls a job finished when a durable completed record agrees.
- Rust worker persists terminal state before terminal callbacks and follows
  Running -> Cancelling -> Cancelled for token cancellation. chapters.json is
  atomically persisted after audio validation and before chapter publication.
  Resume reconciles previous journal audio and protects same-title filename
  collisions without replacing the old terminal manifest contract.

Executed evidence:

- Guarded managed `cargo test -p converter-core --lib worker::streaming_tests
  -- --test-threads=1`: 10 passed before follow-up journal recovery changes.
- Guarded managed `cargo test -p converter-core --lib -- --test-threads=1`:
  76 passed, zero failures/skips, 2.26s test runtime. Shared existing Cargo cache;
  one build worker on final run. Log `/tmp/progressive-rust-final-tests.log`.
  Native Swift bootstrap held the existing /tmp/epub2mp3.heavy-job.lock and
  checked the same host load ceiling. No Python execution or synthesis calls.
- `mise exec -- rustfmt --check crates/converter-core/src/worker.rs`: passed.
- `mise run preflight`: passed local branch/whitespace/conflict checks; this
  task explicitly defers Python/lint/CI gates. No CI monitoring performed.
- `git diff --check` and focused Swift syntax parsing: passed.
- Native macOS helper module typecheck with warnings-as-errors: passed for
  RustAudioRecovery, ResumeStore, JobSnapshot and L10n. This is compiler evidence
  only, not XCTest or app/player behavior.
- Physical `mise run ios:device:preflight` first failed the host load ceiling.
  Focused `IOS_TESTS=... mise run ios:device:test` first hit that limit, then
  reached the real device and was blocked by its passcode. No app build, install
  or XCTest ran. Report:
  `.reports/device/743309B1-04F0-4739-9EFB-02F22E38EBD5/report.json`.
  User was asked asynchronously to unlock. Do not repeat readiness until input
  or changed external evidence. Cached FFI artifact was copied from the original
  worktree for native offline test preparation; it is NOT a rebuilt artifact
  containing the journal changes. No conversion benchmark executed.

Review (Standards + Spec axes): corrected out-of-order first playback, repeated
Play intent after waiting Pause, partial-cache readiness, same-title artifact
collisions, journal union and stable cursor loss when queue offsets are reused.

Remaining required work / acceptance NOT achieved:

1. Typecheck/build complete Apple targets and execute native XCTest/UI/real
   player relaunch tests after device unlock. Reader geometry evidence also
   remains unexecuted; production layout was not changed.
2. Expose true cancellation/reprioritization in Rust/FFI. Cancelling Swift Task
   invalidates delivery only; current synchronous Rust work continues and the
   serial converter can delay another book. Pending navigation still lacks
   Rust priority and durable recovery.
3. Define/test explicit safe restart of Failed/Cancelled jobs and repaired
   Completed jobs. Current core rejects terminal same-ID runs; do not reset
   durable terminal records implicitly. Persisted request range compatibility
   must be completed before treating partial regeneration as reliable recovery.
4. Integrate/rebuild the separate embedded-mobile-audio fix before iPhone live
   synthesis. Current audio.rs still needs external ffprobe/ffmpeg. Original WIP
   files were rechecked and remain untouched.
5. Complete Rust-job offline retention/removal UI reconciliation and immutable
   confirmed transport snapshot adoption across all surfaces. Existing protected
   Apple artifact tests do not prove the new UUID-job lifecycle.
6. Confirm network/interruption/resource policy on the live new narration seam,
   export/manual parity and unchanged clients. Do not claim performance gains.

Resume: use this isolated worktree and branch; read the device report above,
inspect the recorded PID once if needed, then act only on changed readiness.
Run focused native filters AudioPlayerStreamingTests, AudioPlayerResumeMarkerTests,
ResumeStoreTests, ConvertViewModelRoutingTests, ProgressiveNarrationSessionTests,
RustAudioRecoveryTests, AudioPlayerRetentionTests and MiniPlayerBarLayoutTests.
Exclude all opt-in whole-book conversion tests. Rebuild FFI before live shared-
core acceptance. Preserve the original dirty embedded-audio worktree.

Rollback: revert verified owned commits; Apple changes remain separately
reviewable until their gate passes. Ignore the additive chapters.json journal
with old binaries; v1 markers remain readable. Keep books, models, audio and
manifests intact. No cleanup/reset of the original checkout is authorized here.

Delivery checkpoint: Rust worker + this plan committed/pushed as ddb1a27e46
on origin/feature/progressive-reading-session. Apple code/tests are uncommitted
in this isolated worktree, intentionally pending the native gate. Additional
isolated XCTest typecheck including ResumeStoreTests could not complete because
that file also includes DownloadManager/AudiobookManifest helper tests outside
the small helper module. Do not count it as app test/build evidence. No PR opened,
CI monitored, issue closed or release published. The original dirty worktree
status still matches the initial inventory exactly.

### Controlled runtime and native checkpoint

The second execution implements a per-invocation shared ConversionControl:
real cancellation, priority of unstarted source chapters, and pause at the
existing resource-policy boundaries. Additive owned C handles preserve legacy
ABI. Edge cancellation unwinds its pending async request and cleans partial
output; synchronous local inference retains its existing cooperative limit.

Explicit retry creates a new job with recoveryJobId, validates input hash and
provider/voice/language, and reuses validated predecessor audio by hardlink.
Terminal predecessor records/manifests/audio are unchanged. Source selection is
persisted in new job metadata; sourceSha256 is additive in the chapter journal.

Native delivery is serialized and flushed before final handoff. The existing
scheduler publishes network/resource permission without submitting a second
conversion; the native control forwards that permission to Rust. Explicit
Book Detail Listen shares narration; Download retains artifacts without touching
transport. The offline store registers validated audio by hardlink, preserving
its v1 manifest and protecting audible retention through existing cleanup/UI.
Book-level resume keys and pending chapter intent survive successor job IDs.

Evidence: guarded managed cargo test of converter-core + converter-ffi --lib:
88 + 13 passed, no failures/skips (5.92s + 0.66s test runtimes). The initial FFI
fixture failures were fixed by giving the synthetic EPUB a real .epub suffix;
no real books or provider synthesis were executed. Durable logs:
.reports/progressive/controlled-runtime-final-tests.log.

Added mise run mac:test with explicit MAC_TESTS scope and the existing shared
heavy-job lock/load policy. First native macOS run built the shared FFI and app,
ran104 tests:102passed2failed. Those assertions incorrectly assumed raw error
text and that sorted availability equalled the real queue cursor; product
behavior was preserved and expectations corrected. The subsequent run includes
two callback-delivery regressions. Its xcresult is
ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.07_23-16-17--0300.xcresult.
Its native summary proves106passed,0failed,0skipped; the task exited0. This
proves that candidate, not subsequent queue integration or protected-media
reconciliation changes.

Next queue slice: keep raw artifact availability separate from queue ordering.
A validated future/prefix file must not skip an unavailable next chapter.
ProgressiveChapterQueue and native tests define this seam; integrate into
AudioPlayer before removing Session's masking projections, then exercise pending
next/previous/beginning/current-page commands and automatic queue exhaustion.
No layout refactor is needed. Confirm source identity on real AVPlayerItem,
not on the first entry of a sorted JobSnapshot.

The iPhone gate is still the previously recorded passcode blocker; no new device
query has been made without changed readiness evidence. Live iPhone synthesis
still depends on the separate embedded-audio work. Remaining gates include
confirmed versioned transport snapshot/UI adoption, full native lifecycle/UI,
network recovery and reader geometry evidence. Do not mark the goal complete.

Adversarial Rust review fixed two actual faults: resource pause on an empty
queue could stall terminal completion; successor recovery could accept an
existing same-hash symlink outside its output. New regressions prove empty
queue completion and rejection without changing outsider/source data. Final
managed guarded core/FFI --lib run:90+13passed,0failures/skips (6.11s+0.64s test
runtimes), .reports/progressive/reviewed-runtime-tests.log. Formatting checked
with the actual Rust2021 workspace edition. Existing ABI/envelopes preserved.
Explicit Edge retry configuration is verified; historical unresolved engine/model
metadata and local synchronous inference's cooperative bound remain limitations.

### 2026-10-08 queue acceptance checkpoint

ProgressiveChapterQueue is integrated into AudioPlayer, not merely an unused
helper. Session now publishes raw availability; queue admission is contiguous
and source-indexed. Next/previous/beginning/current-page commands retain pending
intent and seek anchors; queue exhaustion waits rather than skipping ready
prefix audio. Pause prevents pending autoplay. Standby relaunch preserves the
saved audio destination even before the first file exists. Existing segment and
remote compatibility paths remain. No reader geometry implementation changed.

Final focused macOS task exited0; native xcresult summary proves126passed,
0failed,0skipped. Evidence exported to
.reports/progressive/native-queue-summary.json; full log:
.reports/progressive/native-queue-final-tests.log. Native xcresult:
ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.07_23-59-29--0300.xcresult.
This includes ten real-AVPlayerItem queue/navigation tests, eight value-queue
regressions, the existing shared-state tests and callback barrier tests. The
initial queue build failed an unused binding under warnings-as-errors; that
binding was corrected before the successful run.

A selected manual range cannot define the full book domain. Added optional
sourceChaptersTotal to Rust terminal manifests/journals and native snapshots;
selected chaptersTotal/progress keep their existing meanings. Old formats
remain readable with unknown source count. Cached legacy metadata discovery is
background-only and never synthesizes. Scoped managed Rust verification:
91core+13FFI+2CLIprincipalpassed (5.65s+0.64s+0.00s test runtime), log
.reports/progressive/source-domain-scoped-tests.log. The broader --bins attempt
failed an existing embedded_edge_probe call to the old TTS signature; that
unrelated probe was not changed or executed. Main product CLI was explicitly
compiled and tested instead. No real book/provider synthesis was run.

Rust control/recovery slice4bbfa6e4f8 has been pushed. Native work is still
uncommitted pending the iPhone gate and final review. Remaining implementation:
confirmed immutable versioned transport snapshot consumed coherently by every
surface; replace process-local reader/playback event delivery through persisted
keys; finish offline legacy-cache reconciliation and network-interruption UI.
Remaining evidence: iOS typecheck/build and XCTest/UI, true relaunch/background/
system-control behavior, seeded reader geometry, and live two-chapter bounded
synthesis after the embedded-audio fix. The physical gate remains the recorded
passcode block; do not query it again until readiness evidence changes.

### 2026-10-08 session authority and transport checkpoint (verification pending)

ReaderSessionState now owns the process-local reading cursor and generation;
compatible persisted keys are recovery storage only. Opening reader B preserves
reader A's active audio item, cursor, and transport. Reader and playback remain
separate authorities. Native reader tests cover late callbacks and opening B
with an actual advancing/paused WAV item; execution is still pending.

PlaybackSnapshot publishes immutable epoch/revision, confirmed native transport,
explicit intent, pending navigation and position through the dedicated clock.
Mini/expanded/macOS transport surfaces consume that state; waiting preserves a
Pause command. Cross-book Play preserves the existing start-position choices,
with reader/session guards on delayed choices. None of these edits changes
reader viewport geometry. Full physical lifecycle/system-control/geometry
acceptance remains blocked by the recorded locked iPhone, without a new query.

Canonical offline playback identities are explicitly excluded from Rust
successor-job lineage; a native regression covers immediate cached-item
admission without invalid recovery identity. Canonical cache reconciliation
and consistent primary-job/source-bound merging are the next dependency.

The original embedded-mobile-audio checkout remains unchanged at its six WIP
paths. Because external probes are a proven iPhone runtime blocker, an
independent in-process Rust audio implementation is now explicitly in scope:
new owned code/dependency edits/tests in this isolated worktree, without copying
or overwriting the original WIP. This is a reviewed integration dependency,
not an assertion that embedded playback or device acceptance already passed.

Executed for this checkpoint: git diff --check and focused Swift syntax parsing
passed. These checks do not prove runtime behavior. Last completed suites remain
91 core + 13 FFI + 2 principal CLI + 126 native macOS tests; new edits require a
fresh scoped runtime run before being counted as verified.

Fresh scoped native execution: `MAC_TESTS=EpubToMp3Tests/AudioPlayerPlaybackSnapshotTests,EpubToMp3Tests/PlaybackClockTests,EpubToMp3Tests/SpeechFallbackPlayerTests,EpubToMp3Tests/ReaderSessionStateTests,EpubToMp3Tests/ReaderProgressStoreTests,EpubToMp3Tests/ProgressiveNarrationSessionTests,EpubToMp3Tests/AudioPlayerNarrationQueueTests CARGO_TARGET_DIR=/Users/pips/Developer/epubtomp3/target CARGO_BUILD_JOBS=1 mise run mac:test` passed: 63 tests, zero failures/skips. Exported local summary `.reports/progressive/native-authority-summary.json`, log `.reports/progressive/native-authority-tests.log`; result `Test-EpubToMp3Mac-2026.10.08_00-17-33--0300.xcresult`. Real AVPlayer advancement/pause and obsolete queue callbacks passed on macOS. UIKit-only reader/player controls and physical lifecycle acceptance remain unexecuted.

Independent in-process audio verification passed under the existing heavy-job
lease: managed `cargo test -p converter-core --lib --test in_process_audio --
--test-threads=1` (91 core + 2 integration tests; 3.69s + 0.97s), followed serially
by converter-ffi --lib (13 passed; 0.38s) and converter-cli --bin converter-cli
(2 passed; 0.00s). No failures/skips. New integration tests execute real MP3/WAV
probes and JPEG/PNG/WebP/WAV cover mutation in a child process with sentinel
external tools, including truncated streams, repeated/front/back cover and
metadata preservation, and unchanged audio payload/invalid-input mutation.
Log: .reports/progressive/in-process-audio-tests.log. Cargo lock was resolved
only in the isolated worktree. This is host evidence, not iPhone synthesis.

Adversarial native review found and addressed explicit-intent retry after a
producer fails, cross-book asynchronous command replacement, canonical partial
queue restoration, and incompatible legacy remote/local chapter axes. The
latter retains the validated remote snapshot intact instead of mixing source
indices silently. Remaining implementation limit: missing chapters in a legacy
remote collection cannot be filled from a differently indexed canonical cache
until an explicit compatible source-identity projection is implemented and
tested. Existing manifests, identities and bytes remain intact.

Expanded native gate ran 179 tests: 178 passed, one failed (canonical partial
restoration). The failure was real: the public seek end tolerance advanced a
restored 1.25-second cursor in a 2-second fixture into the next chapter. Exact
restoration/page anchors now bypass explicit-seek chapter advancement, and old
seek completions cannot overwrite EOF pending navigation. Rerun is required;
.do not count the failed gate as acceptance. Log/native summary retained locally.

A legacy macOS Book Detail path still owned a competing Listen conversion and
replaced another audio queue after manual conversion. Listen now uses the same
progressive session; manual conversion preserves the existing AVPlayer item and
cursor. New native AppKit/player tests cover both paths. A source-parsing listen
assertion has been replaced by runtime tests, not broadened into source checks.

Legacy remote origin was checked against both producers: normal Python server
uses selected ordinal 1...N, its recovery uses ordinal 0...N-1, and Rust HTTP
exposes selected ordinal instead of sourceIndex. Old download manifests contain
no provenance. Such audio is kept for legacy playlist/cursor recovery, never
seeded into the zero-based Rust source queue. Current-page/beginning commands
use the actual book source through Rust; no heuristic migration or data deletion.

Reviewed in-process audio rerun passed: 91 core + 3 audio integration + 13 FFI +
2 CLI principal, zero failures/skips (3.73s + 1.24s + 0.40s + 0.00s), log
.reports/progressive/in-process-audio-reviewed-tests.log. Unsupported native WAV
codecs retain the desktop/Android external capability; valid PCM/MP3 stays fully
in process. Cover input/decoded allocations are bounded, JPEG main-container
termination is checked separately from thumbnails, and invalid covers leave
existing audio unchanged. Independent fixtures and dependencies were reviewed;
original embedded-mobile-audio WIP is still not incorporated or altered.

Fresh expanded native run: 211 tests, 210 passed, one existing AppKit root
pause/resume regression failed. Exact canonical near-end restore and all three
new Mac Book Detail runtime tests passed. The root fixture still writes reader
selection through old defaults and omits the explicit playback book identity;
verify and update it at the new authority seam before treating this gate as
passed. Log .reports/progressive/native-reviewed-tests.log; summary exported.

Additional proven execution gap: the single native Rust invocation queue holds
an entire manual conversion, preventing interactive narration from starting
until it ends. Next focused slice reuses the resource scheduler and Rust controls
to yield background manual synthesis to narration at existing chapter boundaries,
without creating another session owner or parallel converter implementation.
Default book-conversion ABI explicitly selects online Edge; offline routing is
a separate configuration capability and must not be guessed from platform.
