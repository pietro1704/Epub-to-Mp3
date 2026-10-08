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
