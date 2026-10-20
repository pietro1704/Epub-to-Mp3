# Reading/audio contract audit and pending-seek ownership

Date: 2026-10-15. Baseline: `5147fe1d41` with unrelated pending product work.
User priority: reading and synchronization with audio. Delivered correction:
a deferred page request belongs to its job/chapter and is cancelled on teardown.
Measured sentence following remains future work.

## Execution prompt

Objective: exercise READ-1's current timing/identity contract and deliver the
smallest demonstrated correction to reading/audio navigation.
Current evidence: immutable Piper metadata adoption is delivered. Native reader
anchors are proportional; measured sentence timings are absent from Rust/FFI.
Skill route: auto-prompt-execute -> ask-matt routing -> goal-plan-execute
(contract/UI/verification specialists); native-reader-regression for native
invariants and sequential platform verification. Use existing focused XCTest
seams to reproduce a candidate before changing production; tdd for the failing
regression cycle and code-review for independent Standards/Spec review.
Scope: preserve source documents, installed models, progress and unrelated edits.
No timing fabrication, automatic downloads, external provider activation,
renderer replacement, merge, publication or remote CI monitoring.
Acceptance: trace actual producers/consumers; prove and correct pending page-seek
cancellation/identity if reproducible; keep legitimate delayed-duration seeks.
Verification: focused native macOS and SE1/iOS15.5 XCTest, Xcode16.4, one build
job, parallel testing disabled, all Simulators shut down during compilation.
Goal: tracked continuation under the user's prior goal-plan-execute instruction.
Delivery: review exact scoped diff, document real results/limits, commit and push
verified changes under standing project authorization.
Execute now until acceptance is verified or independent work is exhausted.

## Board

| ID | Owner | Dependencies | Acceptance | Status |
| --- | --- | --- | --- | --- |
| READ-1 | contract/UI specialists | Existing runtime | Identify actual timing producers and visible consumers | Audited: measured sentence contract absent; visible navigation is proportional |
| SEEK-1 | Root | READ-1 | Stop/job change drops stale page request; valid delayed request still applies | Verified on macOS and SE: job/chapter ownership, cancellation and valid delayed seek |
| VERIFY-1 | Root / verification specialist | SEEK-1 | Focused runtime red/green, both native platforms, exact reports and limits | Verified: macOS 33, SE 36, host 65; diff and 29 links pass |

## Current contract

- `crates/converter-core/src/epub.rs` defines chapter text/source identity;
  `worker.rs` publishes audio chunks by source chapter and chunk index.
- `crates/converter-ffi/src/lib.rs` exposes the audio chunk callback and queued
  JSON with chapter/chunk/path. No sentence text ranges or measured sentence
  timestamps cross this boundary.
- `StreamingPlaybackChunkDelivery.swift` and `EmbeddedConversionCoordinator.swift`
  enqueue these chunks without sentence IDs.
- `AudioPlayer.activeSentenceId`, `setSentenceTiming`, `SyncEngine` and
  `WordTimingResolver` are infrastructure, with no current visible reader
  consumer or production timing-map writer. Component tests are not evidence of
  end-to-end highlighting.
- UIKit and AppKit publish the first visible text character as a chapter ratio.
  `ReaderPlaybackAnchor` clamps the ratio and clears stale sentence IDs. This
  is approximate navigation, not measured speech alignment.

## Reproduced defect and boundaries

Before this change, `PendingProportionalSeek` owned a chapter index without job identity.
`stop`/player teardown retained it. A deferred duration can therefore apply a
previous request to another book at the same index. An asynchronous current-item
observer sometimes clears pending requests; this does not establish deterministic
ownership or synchronous cancellation. Native AudioPlayer regressions reproduced the ownership/cancellation defect;
no audible cross-book failure is claimed.

Do not repair dormant sentence matching/timing-cache code as a substitute for
connecting the real contract. Future measured synchronization needs versioned
book/job/generation and chapter/chunk/text-range identity, actual interval
provenance, rejection of stale/cancelled events, repeated-text and UTF-8 coverage,
and an honest fallback when timing is unavailable. Preserve exact raw viewport
offset during chrome transitions and canonical offsets for explicit page turns.

## Verification

Read-only prerequisite inspection found Xcode16.4 build16F6, available SE1/iOS15.5
`C66CCB36-C43E-4174-861E-2FA713389C84` shut down, macOS schemes installed, and no
active SimMetalHost/compiler/xcodebuild at inspection time. Artifact existence
alone does not establish compatibility with current source.

Red, cancellation: `mise run native:build:preflight` passed, then the macOS
AudioPlayer regression failed with two assertions: pending ratio remained 0.5
and late duration changed position from 0 to 60 seconds after `stop()`.
This is a native player-state reproduction; no audible cross-book failure is
claimed. Exact logs:
`/var/folders/r_/cm8xzdc94452nmnp7t3wsnwm0000gn/T/reader-sync-red-20261015-25657-gqflou/evidence/report.json`.
The original native result at
`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.15_14-36-40--0300.xcresult`
was read with xcresulttool before Xcode's later test-log retention removed it.
Observed assertion messages are retained separately in
`.reports/reader-sync-20261015/red-observed-failures.json`; this is an observation
record, not a copied xcresult bundle.

No new sentence-synchronization or highlighting feature is claimed by this audit.


### Implemented correction

The pending proportional request now captures its `jobID` as well as chapter
index. Application rejects ownership mismatch before waiting for duration.
Player teardown cancels the request synchronously. A same-job snapshot refresh
preserves it; when a 120-second duration arrives, ratio 0.5 seeks to 60 seconds.
No parser, TTS, timing estimate, viewport or display behavior changed.

Cancellation red/green and job-identity red outputs are retained under
`.reports/reader-sync-20261015/{red,cancel-green,identity-red}/report.json`.
The identity run reported the selected test failing twice and an Xcode result
bundle saving warning (`mkstemp: No such file or directory`); retain the command
logs rather than claiming a complete result bundle for that run.

Final macOS selection through `APPLE_NATIVE_TESTS` / `apple:chapter-callback:test`:
`AudioPlayerDivergenceTests`, `SyncEngineTests`, `ReaderTextHighlightTests`,
`MacReaderPagePlaybackChoiceTests`. **33 passed, zero failed/skipped**, independently
read from xcresulttool summary. Exact output: `.reports/reader-sync-20261015/mac-green/report.json`;
summary: `.reports/reader-sync-20261015/mac-summary.json`.
The latter UI tests exercise real AppKit windows/page choices with silent WAV
fixtures; they neither call Edge nor synthesize/download a voice. Existing Swift
concurrency and ONNX signing warnings remain outside this change.

### Review and remaining limits

Independent Standards and Spec passes found no code blocker or scope creep.
New regressions seed the waiting request through the established test hook and
exercise real AudioPlayer cancellation, snapshot ownership, duration arrival and
published position. They prove player-state behavior; they do not establish an
audible failure reproduced through the reader UI. Existing page-choice UI tests
supplement them. The asynchronous current-item observer's unconditional pending
request clear remains a separate, unproven race; this slice does not claim to
solve every delayed-duration race or deliver synchronized highlighting.

### Exact iOS verification and retained state

`ios:simulator:smoke:build` completed with all Simulators off. Only after the
compiler exited, `ios:simulator:smoke:test` booted the exact SE1/iOS15.5 target
and used `test-without-building`, one job and parallel testing disabled.
**36 passed, zero failed/skipped**, read from xcresulttool's summary. The selection
includes the same player/timing/highlight components, four real UIKit page-choice
cases, and seeded LOTR's repeated/interrupted chrome-toggle UI regression.
The latter asserts no clipped lines and unchanged visible character/raw offset;
it does not establish every font/orientation or dark-mode color correctness.

Exact command logs: `.reports/reader-sync-20261015/se/report.json`.
Summary: `.reports/reader-sync-20261015/se-summary.json`.
Native bundle: `.reports/simulator-smoke-D2CD2017-76B1-4C0B-AA84-BAA074EC1221/tests.xcresult`.
The macOS host exited before iOS compilation. After tests, the existing current
build was resumed with `ios:simulator:resume`; only SE remains open, on LOTR.
Final observed screenshot: `.reports/reader-sync-20261015/final-se.png` (Contents,
paused). Screenshot inspection does not replace XCTest assertions or establish
color/contrast acceptance.

The user reported incorrect dark-mode colors during this verification and
explicitly deferred them. Tracked separately as `READER-20261015-DARK-COLORS` in
TODO_APP.md. No theme change is included here. No model, audio sample or runtime
was downloaded; no online synthesis or remote CI monitoring was performed.

### Final local checks

`mise run preflight` passed **65 host tests / 596 assertions**, zero
failures/errors/skips. Exact output:
`.reports/reader-sync-20261015/host/report.json` and
`.reports/host-workflow/20261015T174609-28463/results/report.json`.
Five research documents' 29 local links/anchors and `git diff --check` passed.
No repository-wide product suite or remote CI was run; these focused checks do
not certify unrelated pending product changes. Only the owned seek correction,
native regressions, research index/audit and two current TODO entries are delivered.
