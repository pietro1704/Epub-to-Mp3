# App delivery backlog

Current user requirements override the historical backlog below. Workflow:
Pending → In progress → Verification → Done, or Blocked with evidence/next action.
Every concrete user request/correction belongs here. Completion requires relevant
tests, cross-platform parity, and commit/push evidence; source presence is not done.
Codex owns Apple implementation; Arch owns Rust/Flutter coordination. Both update
this board and `handoff.md` before crossing ownership or changing shared contracts.

## Active requests — 2026-10-08

- [ ] **APP-20261009-33 — Segment skip buttons use the chapter clock.** Apple verified; parity pending.
  Relative forward/backward controls must cross retained segments using chapter
  time, preserve pause/playing intent, and retain pending targets for missing audio.
  Verify the public skip commands with actual AVPlayer items; keep nonsegment
  behavior and superseded-navigation cancellation covered. Shared Apple slice;
  iOS UI and Flutter parity require their own evidence.
  Red public-command regressions reproduced wrong segment identities. Shared
  relative skip now uses chapter seek; item duration observers preserve chapter
  duration. Estimates cannot clamp or prematurely advance incomplete chapters.
  macOS: 38 passed, 0 failed/skipped; iOS 16: four new cases passed, 0 failed/skipped.
  Evidence in the quality plan. No synthesis or real-book latency claim.

- [x] **APP-20261009-36 — Measure Mac prepared renderer overhead.** Diagnostic verified.
  Performance diagnostic follow-up: measure the actual renderer signature/cache
  miss and disk restore costs for LOTR chapter 8 and Christie chapter 6, with
  complete native attribute equality. Separate cost evidence from 200 ms success.
  One native test passed, zero failures/skips. Median signature/cache miss:
  LOTR 0.377 ms, Christie 0.266 ms; prepared restore 2.267 / 1.729 ms.
  Same-process OS-warm samples only; no production optimization, relaunch,
  registered EPUB-font, clipping or 200 ms acceptance claim. Quality plan has evidence.

- [ ] **APP-20261009-35 — Repair verified model artifact publication on Arch.** Source finding; runtime verification pending.
  ModelStore.install_manifest deletes the verified non-archive .part before
  rename, preventing publication of ONNX/JSON model artifacts. Preserve existing
  installations/downloads. Arch: reproduce at the real artifact publication seam,
  retain verified temporary bytes until rename, close the writer before promotion,
  and verify success/checksum failure preservation with isolated fixtures.
  No local Rust execution or model download; this does not prove offline readiness.
  Apple selector/runtime packaging remain distinct pending requirements.

- [ ] **APP-20261009-34 — Resolve pending seeks after late endpoint confirmation.** Apple verified; parity pending.
  A requested offset beyond an incomplete chapter's estimate must stay pending;
  when its actual terminal duration arrives later, reconcile the target instead
  of waiting for nonexistent segments. Native final-file/segment-handoff evidence
  required; APP-20261009-33 only verifies endpoints known at command time.
  Native segment-only case reproduced an indefinitely pending navigation after
  confirmation. Resolver now rechecks the requested chapter's confirmed end after
  duration loading, retaining request/journey and latest pause intent. Mac five
  focused cases passed, zero failures/skips; iOS 16 three new cases passed,
  zero failures/skips. Source/byte ownership untouched; Flutter parity and
  real-book navigation latency remain unverified. Evidence in the quality plan.

- [x] **APP-20261009-32 — Reader picker import remains responsive and rejects stale selection.** Verified UIKit caller.
  Original import/IO goals: replace the remaining synchronous UIKit reader
  reimport caller with LibraryStore.importBookAsync. Preserve durable import
  behavior and source bytes. Capture request/book/session identity before await;
  stale success may remain in the library but cannot reopen the old reader or
  replace a newer selection. Native picker-delegate heartbeat and stale-result
  regressions, isolated storage/defaults; no layout or conversion changes.
  Native red: both cases failed on blocked MainActor copy heartbeat (`76C409E3...`).
  Final iOS 16: two passed, zero failures/skips (`EF153645...`). Actual worker copy,
  source bytes, fresh library index and newer selection were verified. Guards also
  discard obsolete errors; that branch has review but no dedicated runtime case.
  Shared import implementation/Mac/Flutter unchanged; no broad parity or 200 ms claim.

- [x] **APP-20261009-31 — Measure concurrent projection pressure on catalog delivery.** Verified probe.
  Extend the same literal-book native probe with high versus utility projection
  tasks racing high-priority catalog read/decode. Three bounded samples per book,
  unchanged SHA/fidelity and cancellation of losing work. Measure delivered catalog
  time; do not infer first-window/200 ms success from isolated scheduler samples.
  One native test passed, zero failures/skips (`reader-relaunch-8F611ACD...`).
  Alternating priority order is recorded. Catalog medians with high/utility
  projection: LOTR 135.608/142.431 ms; Christie 12.906/13.568 ms. No demonstrated
  gain from utility priority; production scheduling remains unchanged.

- [x] **APP-20261009-30 — Measure projection validation versus catalog decode.** Verified measurement.
  Use literal/hash-checked LOTR/Christie inputs and chapter 8/6, without synthesis.
  Compare production projection reads (both SHA passes included) with complete
  binary payload decoding, three bounded samples each in isolated temporary
  storage. Preserve source payload/fidelity; permanent native evidence required.
  Isolated timings are not first-window latency or proof of the 200 ms budget.
  One native test passed, zero skips/failures (`reader-relaunch-7E788A03...`).
  Medians: LOTR projection 188.377 ms, decode 118.920 ms, read+decode 130.781 ms;
  Christie 15.822/11.613/12.877 ms. Attachment includes literal source SHA256,
  chapter, byte count, platform/OS, individual samples and measurement limits.
  Projection is not the cheaper isolated route. No production optimization or
  relaxed SHA validation delivered; APP21/200 ms/iOS parity remain open.

- [x] **APP-20261009-29 — Cancel losing reader projection IO cooperatively.** Verified Apple cache slice.
  The Mac opening race cancels the losing task, but the projection store still
  reads/hashes source bytes without cancellation checks. Reject cancelled reads
  and writes before IO and between bounded blocks, preserving SHA validation,
  symlink/file bounds and source-mutation checks. Native read/write cancellation
  regressions plus existing store security cases; no Rust cancellation or 200 ms
  completion claim from this Apple-cache-only change.
  Red: two native pre-cancelled operations failed (`05-00-10` macOS xcresult).
  Final Mac store class: seven passed, zero failures/skips (`05-01-22`). iOS 16:
  two cancellation cases passed, zero failures/skips (`simulator-smoke-3AA1639C...`).
  Cancelled read returns nil; pre-cancelled write throws CancellationError without
  archive creation or source mutation. Cancellation after archive handoff may still
  commit a valid cache write; no rollback/latency improvement is claimed.

- [ ] **APP-20261009-28 — Active chapter presentation before catalog hydration.** In progress.
  Integrate the source-bound projection into actual native reader presentation.
  Start with the Mac adapter and deterministic window tests: complete current
  chapter/progress/anchor before blocked fulltext decode; catalog hydration must
  not repaint or rewind. Keep controlsUsable gated on the full validated catalog.
  Invalid/stale projection falls back to the existing complete-book route. Preserve
  navigation and generation fences. iOS parity and actual two-host 200 ms gate
  remain required before parent APP-20261009-21 can close.
  Mac behavior verified: current chapter/progress/canonical EPUB anchor before
  blocked hydration, no rewind on matching hydration, changed source fallback,
  obsolete presentation rejection, font change during restore and early-close
  persistence. Nine cases passed in the wider run (`04-35-32`); two focused cases
  passed after correcting the mismatch fixture (`04-37-31`); five active-chapter
  cases passed after first-arrival catalog/projection scheduling (`04-44-36`).
  Actual two-host budget remains red: LOTR 363.818 ms, Christie 151.933 ms in
  `reader-relaunch-5E61AC9C-5B83-4152-83DD-5173B9B71F89`. No synthesis or threshold change.
  iOS presentation integration and full APP21 acceptance remain open.

- [x] **APP-20261009-27 — Reader document preparation off the UI executor.** Verified Apple worker slice.
  Original goal item 6: UIKit calls synchronous EPUB extraction from its main-actor
  loading task. Add one explicit background preparation entry point and reuse it
  in the Apple adapters, retaining the existing parser/result semantics. Verify
  actual parser thread, responsiveness under a blocked worker and source fidelity.
  Fence UIKit book/load generation immediately after the new await. No layout,
  provider, synthesis or 200 ms completion claim. Mac's existing nonisolated async
  wrapper is not claimed to have blocked the main actor.
  Evidence: three Mac cases passed (`04-06-39`); revised heartbeat passed separately
  (`04-12-43`). iOS fidelity/thread case passed in `261611C0...`; the revised
  heartbeat passed alone in `09E7C00E...`, zero skips/failures on both reruns.
  The first iOS heartbeat depended on XCTest observation latency; the worker now
  requests its MainActor release directly, retaining the same two-second deadline.
  Parser semantics/source bytes unchanged. Cancellation does not interrupt an
  already running detached parse; controller generation rejects obsolete results.

- [x] **APP-20261009-25 — Manual Book Detail conversion preserves playback.** Verified Apple adapters.
  Original goal item 3: both native detail adapters still replace the player on
  manual completion (macOS also stops it). Remove those session mutations while
  retaining conversion result/history. Exercise actual native entry points with
  an injected conversion executor, before and after completion; cover an existing
  session and an idle player. No provider call, whole-book synthesis or cleanup of
  user data. Keep progressive Listen and chapter-first relaunch work open.
  Evidence: macOS two passed, zero failures/skips (`02-46-53` xcresult);
  iOS 16 two passed, zero failures/skips (`simulator-smoke-38898F9F-EADD-488B-800A-E065CDBFC343`).
  Native AVPlayer progression and unchanged AVPlayerItem were checked before/after
  manual completion and progress/chapter callbacks. History reloaded after flush.
  FFI/Rust/Flutter unchanged; Flutter runtime parity remains for Arch to verify.

- [x] **APP-20261009-26 — Native iOS Listen must consume progressive delivery.** Verified complete-chapter bridge.
  Original goal playback/performance: MainReaderScreenController.startListening
  awaits the whole default conversion before installing playback and does not
  supply the reader priority chapter or chapter-completion callback. Restore
  chapter-first progressive delivery without whole-book benchmark synthesis,
  duplicate jobs, stale-book autoplay or silently changing configured providers.
  Native controller/AVPlayer evidence required, not a source-contract assertion.
  Slice: inject the existing Rust executor, capture priority/job ownership before
  async file resolution, consume complete-chapter callbacks in source order,
  preserve the current item on finalization and honor pause while waiting.
  Verify out-of-order delivery, duplicate Play, stale book/player session and
  paused completion with native UIKit/AVPlayer and isolated fixtures. No layout
  changes or new synthesis. Segment delivery/200 ms/Flutter acceptance stay open.
  Evidence: iOS seven cases passed in `E656DF68...`; the replacement-session case
  passed separately in `86DB3D4C...` after correcting its expectation to preserve
  the recipient's converting state. No production change between those runs.
  macOS shared pause regression: one passed, zero failures/skips (`03-42-31`).
  The requested audio file advanced before fake conversion completion; finalization
  retained its AVPlayerItem and respected pause. Private session defaults prevent
  app-host cleanup from invalidating isolated library fixtures; production stays
  on standard defaults. See the goal plan for full evidence and limits.
  Final data-safety audit: meaningful previous position is paused/persisted before
  transport teardown. An additional iOS case passed (`437B1056...`, zero skips/fails),
  reading a fresh ResumeStore marker at 4 seconds with wasPlaying=false.
  Total iOS coverage is nine cases across seven + one + one focused executions.

- [x] **APP-20261009-24 — Honest reader readiness after saved-position restore.** Verified macOS slice.
  Part of APP-20261009-21: macOS readiness must follow committed layout and saved
  passage restoration, not precede a queued restore. Reject stale restore callbacks
  after a book/load/chapter change. No 200 ms claim from telemetry alone.
  Scope: Mac reader presentation/restore and native window regressions; iOS already
  uses stable-layout completion and remains unchanged. Verify chapter-boundary
  navigation alongside the new focused readiness test, then commit/push.
  Native red case proved ready at offset 0 instead of the saved 33600.6; another
  red case proved early close persisted 0 instead of 0.6. Final focused run:
  six passed, zero failures/skips, macOS xcresult `02-36-12` on 2026-10-09.
  Four readiness/lifecycle/page-turn regressions plus two chapter-boundary cases.
  No 200 ms acceptance, real-book latency improvement or Flutter change claimed.

- [ ] **APP-20261009-23 — Resume goal with both actual books on Simulator.** In progress.
  User confirmed the app opened. Validate The Lord of the Rings and E não sobrou
  nenhum using native automation on the authorized iOS 16 iPhone SE Simulator.
  Keep conversion limited to LOTR 8–9 and Christie 6–7, zero-based inclusive.
  Preserve original books, models, downloads and existing playback artifacts.
  Reuse the verified four-chapter benchmark where unchanged; distinguish reader,
  playback and latency acceptance from conversion success. No whole-book TTS.
  Conversion recheck passed: exactly one native benchmark, zero failures/skips,
  four valid MP3 artifacts, Christie 5.286 s and LOTR 186.526 s; no audio reuse.
  Evidence: `docs/plans/2026-10-09-simulator-real-books-recheck.md`.
  Latest requested repeat `8A081C2E` also passed 1/0/0 with four valid artifacts:
  Christie 21.643 s, LOTR 252.736 s, one LOTR retry, no audio reuse. Logs show
  max_in_flight=1. Total synthesis worsened; performance acceptance stays open.
  Reader navigation, audible playback and 200 ms relaunch acceptance remain open.
  Verified shared Swift configuration slice: chapter completion snapshots no
  longer invent an Edge provider when the Rust event supplies no engine. Native
  callback-to-snapshot regression failed on "edge", then passed 1/0/0 on macOS.
  No iOS UI, Flutter, model-selector or performance completion claim.

- [x] **APP-20261009-22 — Source-bound active chapter storage.** Verified storage-only slice.
  Persist complete active chapter data and lightweight book/TOC metadata in the
  existing bounded/checksummed archive primitive, separate namespace. Bind to the
  current fulltext file SHA256; changed/missing/unsafe fulltext is a cache miss.
  Native fidelity/invalidation tests first; no controller integration, 200 ms or
  later-navigation completion claim until those seams are exercised separately.
  Evidence: five focused macOS XCTest cases passed, and five iOS 16 Simulator
  cases passed with zero failures/skips in `simulator-smoke-DA9212BD-9AA6-41A7-B61E-41F24093C103`.
  Review confirmed descriptor-based source reads, symlink rejection and source
  revalidation after archive await. Flutter has no consumer of this Apple cache.

- [ ] **APP-20261009-21 — Active-chapter relaunch critical path.** Profiled; implementation pending.
  Two-host actual-window profiling confirms prepared attributed archive hits;
  LOTR full-book read/decode ~130 ms, restore ~5 ms, presentation ~5 ms, initial
  window/attach/layout cumulative ~93 ms. State/table setup ~23 ms includes restore.
  Preserve 200 ms gate and source/style integrity; avoid decoding the whole book
  before restoring the active chapter. Detailed evidence in
  `docs/plans/2026-10-09-reader-opening-profile.md`. No source fix claimed; temporary
  tagged probes removed, original cache/book bytes preserved.

- [x] **APP-20261009-20 — Avoid duplicate prepared-renderer signature work.** Verified narrow slice.
  Reuse the already computed signature for memory lookup; retain full source/style
  identity and post-await validation. Memory restoration regression checks complete
  attributed-text equality and independent object identity. Five native Mac tests
  and five iOS16 tests passed, zero failures/skips (`65B9724B...`). No source/cache
  invalidation relaxation. Same-input two-host run `reader-relaunch-8670ECE5...`:
  prepare passed, verify remains red, LOTR 721.65 ms and Christie 126.87 ms versus
  unchanged 200 ms acceptance. No causal speedup or full latency completion claim.

- [x] **APP-20261009-19 — Optimized Apple Simulator conversion artifact.** Verified artifact/smoke scope.
  One-job Apple-only artifact build under the existing explicit exception; no Rust
  algorithm/validation weakening or Flutter execution. Use current sources with
  Release optimization to avoid interpreting unoptimized MP3 decoding as product
  latency. Verify Mach-O/ABI, explicit bundling profile and native callback/correctness
  before any scoped same-book measurement. Keep original books/models/audio intact.
  Release Rust build passed in 6m37s. Real artifact/ABI/architecture/platform,
  invalid-library rejection and signed bundling regression passed. Explicit
  CONVERTER_FFI_SIMULATOR_PROFILE=release allows optimized Rust in the Debug app;
  default Debug behavior and device/macOS routing unchanged, invalid profile rejected.
  Actual app build passed; native iOS16 bundled-load/catalog and literal callback
  path checks: two passed, zero failures/skips (`AD657EC3...`). No synthesis or
  speedup claim in this preparation slice. Matched measurement remains in APP-16.

- [x] **APP-20261009-18 — Explain rejected benchmark chapter callbacks.** Verified diagnostic slice.
  Preserve job/range/owned-parent/MP3/readability guards; record each rejection
  reason in benchmark measurements and failed-delivery message instead of silently
  dropping the event. Offline native regression covers every guard, literal paths
  and existing symlink escape. Mac focused set: three passed; iOS16 focused guard
  regression: one passed, zero failures/skips (`1BC00B18...`). No new synthesis.
  This enables the next scoped run to distinguish no event from a rejected event;
  it does not resolve or waive the existing LOTR callback/performance gate.

- [x] **APP-20261009-17 — Preserve literal local chapter paths across Swift/FFI.** Verified.
  Generic URL decoding truncated #/? and decoded percent escapes in raw filesystem
  paths. Custom event decoding now constructs a file URL from the literal absolute
  POSIX path; relative, tilde, URI and NUL paths rejected. Existing memberwise init
  preserved. Native TDD Mac: red before fix, two green after; final strict variant
  two passed. iOS16: two passed, zero failures/skips (`4A12FD57...` xcresult).
  This proves decoder correctness, not the cause/resolution of LOTR benchmark's
  missing chapter callback. Rust/Flutter wire contract unchanged, Apple clients share fix.

- [x] **APP-20261009-16 — Scoped Simulator conversion evidence.** Verified bounded conversion run.
  Continue the full goal independently of the unresolved reader gesture test.
  Same SHA-verified originals, LOTR 8–9 and Christie 6–7 inclusive zero-based,
  new UUID jobs, temporary input/output namespaces, no audio reuse or autoplay.
  Prepared native benchmark specification/xctestrun in
  `simulator-conversion-5D99D6F4-F11B-464E-B09C-6C617216E633`.
  Reuses existing build and Xcode 16.4 CLI controller; operation limit 900 s,
  thermal/memory safeguards stay active. Simulator is not a matched phone baseline.
  Completion requires executed native test, exact playable outputs and report;
  preparation/start alone is not success.
  Execution `simulator-smoke-97F282D7-844C-4669-9E3E-8A93B5913A0E` reached LOTR
  TTS chunk 19/~21, success responses; chunks changed 4096→3072→2304→2048 and
  concurrency 2→1, showing adaptation of pending work. No final MP3/chapter verified.
  Load-only safeguard stopped at 45.07 after startup grace; memoryPressure=1,
  thermal=fair. No native XCTest pass or full synthesis duration established.
  Native draft report defaults failed until completion, counters are not live;
  zero report counters did not mean synthesis had never begun. Preserve partial
  logs/spec/report; do not rerun unchanged or use this as a speed comparison.
  Optimized Rust run `DC6480EE...`, xcresult `28B96974...`: one benchmark passed,
  zero failures/skips, exact four playable chapters, fresh jobs and no audio reuse.
  Christie 6–7: 5778 chars, 349.248 s audio, 6.0183 s conversion; first chapter
  delivery 2.8305 s. LOTR 8–9: 112357 chars, 7007.16 s audio, 199.4277 s conversion;
  first chapter delivery 121.5554 s. All delivery rejection arrays empty; one LOTR
  retry, no throttles. Native test interval 213.031 s, no rebuild/synthesis skip.
  This verifies functional scope and yields a Simulator sample, not a controlled
  causal speedup or matched phone comparison. Provider/voice snapshot fields remain
  unmeasured; first delivery is not first audible sound, memory samples are not peaks.
  Revised bounded observation window (explicit opt-in up to operation budget;
  memory/thermal/deadline safeguards retained), Christie first. Run `2C4CA9AC...`
  / xcresult `6BFC9F2C...` executed one benchmark, failed on LOTR's first-delivery
  callback expectation (2 s), not the host load safeguard. Christie 6–7 verified:
  5778 chars, two playable outputs, 349.248 s audio, 31.6898 s synthesis.
  LOTR published both requested chapters but failed delivery validation; 591.382 s
  conversion interval, no final accepted audio/duration claim. Total test 676.87 s.
  One-second stack sample identified CoverArtwork.embed_into → validate_audio →
  inspect_mpeg/Symphonia full decode in unoptimized Simulator Rust Debug. Preserve
  validation, route shared-code investigation to Arch; no production speedup claim.

- [x] **APP-20261008-14 — Bundle the correct Rust library for Apple Simulator.** Verified packaging/smoke scope.
  User authorized building the Apple Simulator Rust artifact on this Mac for this
  slice only. Keep Rust embedded in the app process, not a sidecar/service.
  Select physical iOS vs Simulator architecture/platform explicitly, reject wrong
  Mach-O/ABI inputs before copying and sign the bundled dylib. Preserve macOS route.
  Build with Simulator shut down, one job and shared lease; no Python/Flutter/CI.
  Acceptance: wrong-platform rejection, real Simulator artifact verification,
  bundled verification and a focused native app test. No full-book conversion.
  Rust Debug x86_64 Simulator build passed (4m43s); explicit rustup compiler avoids
  Homebrew rustc's missing target sysroot. Packaging regression passed: device/macOS
  and incomplete ABI rejected; real device/Simulator accepted; signed copy verified.
  Actual app build-for-testing passed (`simulator-smoke-AFCEF095-4935-4134-815F-1700B702B283`).
  Embedded app dylib verified x86_64/IOSSIMULATOR with strict codesign verification.
  Native test attempt `simulator-smoke-F317C627-7D57-4741-A478-17210E8F5920` was
  interrupted by load watchdog (>12), no valid completed xcresult or test result.
  Late queued boot required a second exact-device shutdown; confirmed none booted.
  Helper now explicitly boots/waits before XCTest and watches boot as well as tests.
  Retry preflight refused at load 15.58, no boot. CleanMyMac HealthMonitor observed
  at 165% CPU, not a proven sole cause. App startup/UI acceptance remains unchecked.
  Authorized monitor-stop retry: TERM auto-respawned; SIGSTOP confirmed new PID
  47251 paused. After idle load fell to 3.64, initial Simulator migration still
  crossed instantaneous limit (14.88), before app/tests. Earlier TERM-only boot
  reached 22.91. Evidence `simulator-smoke-29F6531C-F0D0-4302-9B50-E7160960D3DF`
  and `simulator-smoke-1C812944-BFEC-4781-9539-C1355D13F8EA`. Monitor resumed with
  SIGCONT; no booted devices. pmset showed no thermal/performance warning and CPU
  limits 100%; load threshold abort is not evidence of app failure or a new crash.
  Boot-grace/resource-policy adjustment needs explicit risk agreement, not blind retries.
  User explicitly authorized startup grace. Opt-in `IOS_SIMULATOR_BOOT_GRACE_SECONDS`
  caps at 180 s, default zero; this run allows 120 s while thermal serious/critical,
  critical memory pressure or a 300 s operation deadline still stop the exact device.
  Xcode 26 controller failed runner handshake/rebooted Simulator; old runtime also
  produced recurring SafariBookmarksSyncAgent SIGSEGV (not attributed to app).
  Reused identical build with CLI Xcode 16.4 controller: two passed, zero failures/skips
  in 28.8 s, `simulator-smoke-DE4C11CC-6D0F-45A7-BF48-390021F1E01C`.
  Native bundled Rust catalog call and library search both executed. App left open
  on Library in Simulator GUI; no Xcode GUI. Scope is smoke, not conversion/perf completion.

- [ ] **APP-20261008-15 — Test actual LOTR and Christie books on iOS Simulator.** In progress.
  User requested resuming the quality/performance goal using both real EPUBs.
  Preserve original imports/models/audio; no physical-device run. Verify reader
  behavior first; conversion limited to LOTR 8–9 / Christie 6–7 (zero-based inclusive).
  Report Simulator measurements separately from physical-device historical evidence.
  Both exact source hashes verified and copies imported through the app's seed/import
  path; real covers/titles and two-column grid visible. Initial UI run: Christie
  passed, LOTR failed AX test-only button hit. Real swipe/coordinate-drag variants
  subsequently failed page change on both books even after loading cover disappears.
  Evidence: `simulator-smoke-66FB4514-375D-4578-A645-8FC7B84E6B28` (1 pass/1 fail),
  `simulator-smoke-A24EEE2E-2AF1-49D0-B458-9383A04BB856` (2 failed, zero skips).
  No conversion or autoplay. Temporary tagged gesture/readiness logging added for
  one focused Christie reproduction; remove before verified delivery.
  Further diagnostics: navigationReady=1 but pan callbacks absent; actual screen
  geometry confirmed viewport (0,76,375,447) within window (0,0,375,667).
  Matching Xcode 16.4 isolated UI runner also reproduced failure (`72035EA7...`).
  Moving pan ownership (`ECCAEB51...`) and paginated simultaneity (`2B39CA70...`)
  did not fix the exact same page-change assertion; both candidates reverted.
  Text-selection-disable experiment timed out, inconclusive (`F9784EED...`).
  All temporary production instrumentation/selection changes removed. Reader
  test remains red/uncommitted; no source fix or conversion performance claimed.

- [x] **APP-20261008-13 — Faster Apple download/extraction defaults.** Recorded.
  Prefer xcodes/aria2 downloads and experimental unxip for Xcode `.xip` archives.
  CLI help confirms the flag; `/usr/local/bin/aria2c` exists. Runtime `.dmg`
  installation does not use unxip. Retain active useful partial downloads and
  serialize heavy work on this Mac; this policy is not a speed benchmark claim.

- [ ] **APP-20261008-12 — Lightweight legacy iOS Simulator intermediate goal.** In progress.
  Latest user correction: all subsequent iOS validation uses Simulator only, not
  the physical iPhone. Install the oldest compatible runtime and use one small-screen
  iPhone; launch and run focused native app tests without opening Xcode GUI.
  This Intel Mac has 8 GiB RAM and reported crashes with iOS 18/26: no automatic
  fallback to those runtimes, no concurrent heavy jobs, no Python or data deletion.
  App deployment floor: iOS 15.0. Installed runtimes: 18.6 and 26.3, both stopped.
  Determine actual host/toolchain runtime compatibility before booting anything.
  Goal service rejected a second active goal; track this as an intermediate slice
  of the existing quality/performance goal, without marking that goal complete.
  Standard `xcodebuild -downloadPlatform ...15.0` returned unavailable. Official
  legacy catalog supplied iOS 15.0 build 19A339 (5,304,795,932-byte DMG), downloaded
  under `.reports/simulator-ios15/`; hdiutil checksum and Apple package signature
  verified. Installer estimates 11,252,916 KiB installed. No runtime booted.
  Correction: recommending `installer -target /` was wrong. PackageInfo has no
  install destination and payload starts at `Contents`; user-authorized installer
  PID 43721 logged protected system-volume rejection on 2026-10-08 22:04:58.
  Runtime is not installed. CLI `-importPlatform` also rejected this legacy package
  DMG (SimDiskImageError 10). Do not retry root installation or alter system protection.
  Apple documents iOS 15 Simulator unsupported on Sonoma; host compatibility must
  be checked separately from the app's iOS 15 deployment floor.
  Next candidate: iOS 16.0 and a small compatible device. CLI download returned
  unavailable; official legacy URL redirects to Apple Developer unauthorized page.
  Direct curl required authentication, but xcodes 2.1.0 successfully downloaded
  and installed iOS 16.0 (20A360); simctl reports Ready. Earlier download blocker
  was not exhaustive: prefer xcodes rather than transferring legwork to the user.
  Created SE second generation `381DBE17-FFAB-4A2E-B35F-AB9FEC92C14E` (first-generation
  SE does not support iOS 16). Boot began migration, but host load rose from 1.93
  to 62.95 without parallel builds. Shut down the exact device immediately;
  do not interpret bootstatus's shutdown terminal message as successful readiness.
  App opening/tests remain unverified: unsafe observed host load and no compatible
  app/Rust Simulator artifact. No iOS 18/26 boot or physical-device run.
  Full embedded runtime validation also requires the missing Intel iOS Simulator
  Rust artifact (`x86_64-apple-ios`); Arch owns that build. Physical arm64 iOS and
  x86_64 macOS binaries are not substitutes. App launch/tests remain unverified.

- [x] **APP-20261008-11 — Faster compatible fulltext cache decode.** Verified cache behavior.
  Binary plist primary, fallback to existing durable/legacy JSON; preserve older
  bytes during migration, atomic writes and format-aware scoped cleanup/budget.
  Verify native roundtrip fidelity, migration/corruption/removal and same-book
  two-host readiness. No source/model/download changes or Rust/Flutter execution here.
  Mac: 13 cache/native-window tests passed, zero skips (`21-37-41` xcresult).
  Two-host run `reader-relaunch-86F998D4-805C-4493-A999-99819BB90ED9` prepared
  successfully; LOTR improved 439→355 ms but still fails unchanged 200 ms budget.
  Physical iOS `E28AEFD2-00D3-4336-B79F-DD9AC2ACC6F4`: 17 passed, zero failures/skips,
  including cache, renderer and actual UIKit window. Total 42.80 s (build 28.04 s,
  tests 11.17 s); no conversion. Binary cache slice verified for both Apple clients.
  Further latency work remains necessary under APP-20261008-07; no 200 ms claim.
  Removed duplicate pre-lookup signature computations without changing the
  post-await validation; five native renderer tests passed (`21-47-20` xcresult).
  Retested same two hosts in `reader-relaunch-20E82812-A483-459F-87D0-0A751F1C2D32`;
  200 ms acceptance still fails. No speedup/completion claim from this change.
  Signature micro-optimization remains a separate uncommitted renderer slice.

- [x] **APP-20261008-10 — Integrate prepared chapter restoration in Apple readers.** Verified behavior.
  Shared renderer binds complete chapter/settings/font/platform inputs; memory hits
  stay synchronous, disk IO is bounded off-main, archive restoration stays MainActor.
  Both controllers fence stale load generations and retain image/plain/HTML fallback
  and existing viewport geometry. Envelope v2 checks archive SHA256 before decoding.
  Mac storage/renderer/window verification: 17 passed, zero skips (`21-27-36` xcresult).
  Physical iOS focused set: 17 passed, zero skips (`CAB5B9A6-A73C-4299-9E4D-3C3EF9A7451D`),
  plus actual UIKit window integration passed (`2898D60B-28A6-49E6-8465-9442DD25EEA9`).
  UIKit archive comparison initially failed on fixed color representation; normalized
  fixed colors to public sRGB UIColor while retaining dynamic colors, kept full
  equality checks and passed. Native UI fixture explicitly drives its layout passes.
  Two-host native measurement `reader-relaunch-353E8583-ECE5-49E7-9B93-0F7B7A9BF19B`:
  prepare passed; verify remains red, LOTR 439 ms >200 ms. No threshold relaxation,
  budget remains in APP-20261008-07; this completes restoration behavior, not 200 ms.

- [x] **APP-20261008-09 — Safe prepared chapter archive persistence.** Verified.
  Shared Apple actor; immutable archive bytes, book/chapter/signature binding,
  bounded reads, atomic writes, corrupt/mismatch cache misses and owned-only removal.
  Verify isolated native durability, preservation, symlink/size guards and off-main IO.
  No reader fast-path integration or 200 ms claim in this storage slice.
  Nine native macOS tests passed, zero skips (`20-34-11` xcresult). Default 64 MiB
  budget rejects new writes without eviction; file reads/writes cap at 8 MiB.
  Physical iOS storage tests passed in the focused set above. Envelope v2 adds
  archive checksum validation; earlier locked attempt did not build or test.

- [ ] **APP-20261008-07 — Verify native reader readiness after process relaunch.** In progress.
  Two separate native macOS XCTest host executions, same hash-checked LOTR/Christie
  inputs and test-only book IDs. Require disk-prepared content and controls within
  200 ms in the new process; no in-memory prewarm substitute. Preserve all existing
  cache/library data, restore reader defaults and remove only owned test fixtures.
  Red: prepare passed one native test; verify failed one (zero skips), actual
  disk-prepared open 2446 ms >200 ms. Evidence:
  `.reports/mobile-audio/reader-relaunch-628B5899-4B2F-442D-9526-C40779A7AA43`.
  Relaunch test implemented; overall 200 ms acceptance remains unverified/failed.
  Removing redundant MainActor cache rewrite reduced one LOTR sample to 985 ms,
  still failing. Focused profile `reader-relaunch-17AFA62C-9C7B-44CF-951F-9AD1BC083342`:
  LOTR read/decode 241 ms, HTML render 537 ms, TextKit fit 1.6 ms; Christie
  18/16/10 ms. Temporary probes removed. Relaunch test remains uncommitted;
  decoding/render preparation, not viewport layout, needs further work.
  Codec experiment verified: actual typed JSON/plist roundtrips preserve all fields,
  one native test passed with zero skips (`reader-relaunch-3071CE3E-E1C4-4571-9172-948B12E9C8B1`).
  LOTR JSON decode ~213 ms versus binary ~104–118 ms; binary grew 25.09→26.54 MB.
  No production cache migration: this alone cannot fix the 537 ms HTML render.
  Prepared native attributed-text experiment passed one test, zero skips
  (`reader-relaunch-39737E0E-1C15-4C50-9581-006E94EEEB92`): LOTR chapter 8
  HTML render 594 ms vs secure archive decode 0.40–0.65 ms (11,702 bytes);
  Christie chapter 6 16.16 ms vs 0.38–0.55 ms (17,194 bytes).
  Full text/attribute equality checked on each decode. In-memory experiment only;
  durable integration, settings invalidation and actual relaunch remain pending.

- [x] **APP-20261008-08 — Avoid redundant Mac reader cache writes.** Verified.
  Cold-write follow-up verified on macOS: first EPUB fulltext persistence and
  cache collection execute off MainActor, with load-generation fencing after IO.
  Red native controller probe caught main-thread persistence; green five readiness
  tests plus one stale-selection test, no failures/skips. Durable bytes checked.
  No new 200 ms, iOS UI, real-book timing or Flutter completion claim.
  Disk-prepared content no longer reencodes/writes/enumerates cache on MainActor.
  Native window regression asserts readable content/controls and unchanged durable
  bytes/mtime: one test passed, zero skips, `20-20-19` macOS xcresult.
  Cold imports still persist; iOS persistence was already dispatched off-main.
  This IO correction does not satisfy APP-20261008-07's 200 ms relaunch budget.

- [ ] **APP-20261008-06 — Investigate slower LOTR adaptive conversion on Arch.** Pending.
  Physical candidate `699FF2AE-0A79-406A-889C-FEF3EF01110F` passed one benchmark,
  zero skips, exact LOTR 8–9/Christie 6–7, no audio reuse. LOTR 310.40→432.12 s
  (+39.2%); Christie 6.34→6.35 s. Initial Edge replies were much slower than baseline;
  profile shrank 4096/2→2048/1 without recorded retries/throttles. This one network
  sample does not isolate policy causality. Arch owns Rust diagnosis/verification;
  retain ordered output and pressure/cancellation behavior, measure controlled
  throughput before changing adaptation. Apple revalidates the resulting artifact.

- [x] **APP-20261008-05 — Preserve manual Mac conversion inbox inputs.** Verified.
  Additional shared Apple safety slice verified: synchronous
  SharedContainerImporter.drain retains failed payloads, matching the async caller.
  Failure reproduced, then three sync tests and one async test passed on macOS;
  failed expanded EPUB bytes unchanged, successful inbox payload still drained.
  Evidence in the quality plan; no iOS UI or Flutter verification in this slice.
  Audit found `ConvertViewModel.importForConversion` removes the entire inbox
  before copying. Acceptance: earlier files survive successful/failed subsequent
  imports and reimport from within the inbox; cleanup targets only owned staging.
  Verify at the actual native import boundary with isolated files.
  Compatibility helper only: current UI has no caller. Three native regressions
  reproduced lost prior inputs/source (`19-31-29` macOS xcresult, all three failed).
  Green: four native tests passed, zero skips (`19-32-33` macOS xcresult).
  Each import retains its own UUID directory; failed copies remove only that directory.

- [ ] **APP-20261008-01 — Two books per library row.** In progress.
  Acceptance: exactly two book cards per row on iOS, macOS and Flutter, including
  narrow/wide widths and resizing; retain cover ratio, labels and existing actions.
  - [x] iOS: 18 physical XCTest passed, zero skips; `E539FCA1-3855-46EC-8AA2-C78BBC31D31D`.
  - [x] macOS: actual NSCollectionView resize regression passed (1 test, zero skips),
    `Test-EpubToMp3Mac-2026.10.08_19-22-48--0300.xcresult`; stale document width fixed.
  - [ ] Flutter (Arch only): widget regression implemented for phone/wide resize;
    run `flutter test test/library_screen_test.dart --plain-name 'library grid keeps two columns across phone and wide resize'` on Arch, not this Mac.
  - [ ] Delivery: inspected diff, synchronized behavior, commit/push.
- [ ] **APP-20261008-02 — Quality/performance goal.** In progress.
  Acceptance/evidence: `docs/plans/2026-10-08-app-quality-performance.md`.
  Remaining: relaunch readiness and the observed conversion performance regression.
  Full physical seven-class sequence passed: `D379076E-DD02-49A1-9DA3-BAA4C728648F`,
  112 passed, zero failures, one opt-in existing-audio measurement skipped;
  no rebuild, 54.64 s total. Earlier playback failures did not reproduce.
  Bounded physical synthesis comparison completed: `699FF2AE-0A79-406A-889C-FEF3EF01110F`,
  exact four playable chapters, one passing test, zero skips, 451.39 s total,
  no rebuild/audio reuse. See APP-20261008-06; performance is not marked resolved.
  Latest device evidence: `0132B263-6FB2-49B1-A195-9627078459AE` (two tests passed)
  and `B882C802-84BE-4447-A0BD-23387F54BFF1` (35 seek tests passed), zero skips.
  Replacement-player regression and initial AVPlayer diagnostics verified on iPhone;
  the suspected old-player session failure did not reproduce. The full sequence
  also passed above; neither establishes the earlier failure's root cause.
  Lifecycle termination barrier: one macOS XCTest passed, zero skips,
  `Test-EpubToMp3Mac-2026.10.08_19-25-41--0300.xcresult`. The isolated regression
  invokes the real termination callback while index encoding is blocked.
  iOS lifecycle: three physical tests passed, zero skips,
  `E06BBEA9-291E-41F8-A2B8-8BBE5D3890E9` (33.64 s total, 24.51 s build,
  7.51 s test interval). Real termination/background callbacks flush isolated
  queued changes; stale generation cannot end its replacement grant. Expiration
  logic is invoked directly, not delivered by the OS. Conversion comparison pending.
  Conversion report instrumentation: three native report/monotonic delivery tests
  passed (`19-28-01` macOS xcresult), plus real task_info capture passed (`19-28-53`),
  zero skips. Added point-sampled footprint and first published-chapter callback
  latency; neither is acoustic latency/peak memory or a baseline comparison.
- [x] **APP-20261008-03 — Shared request tracking and platform parity policy.**
  Registered in `CLAUDE.md`/`AGENTS.md`, this board and `handoff.md` for Codex/Arch.
  Verified by documentation read-back and scoped `git diff --check`; historical instructions
  do not authorize CI/PR monitoring, Python/Ruff local execution or Simulator use.
- [x] **APP-20261008-04 — Host ownership correction.** Registered.
  This Mac performs macOS/iOS work only. Arch performs Rust/Flutter execution and
  validation. Flutter checks remain pending until Arch returns actual test evidence.
  Every future concrete user request/correction updates this board automatically.

## Historical backlog (requires revalidation; not current platform scope)

The original iOS-only scope and old verification recipes below are historical.
Current work must keep iOS/macOS/Flutter parity and follow root instructions.

> Gerado em 2026-07-10. Fonte: BUG_SPRINT.md/TDD_PLAN.md do iOS estão 100%
> resolvidos (bugs 1-8, ver commits 2d0cf59..8a179ae) — não há bug conhecido
> aberto. Os itens abaixo são gaps de escopo/arquitetura identificados via
> memória do projeto + estado atual do repo (sem TODO/FIXME reais no código).
> Edite livremente antes de rodar o prompt no final.

## Itens a resolver (foco: iOS)

> Flutter/multiplataforma fora de escopo por ora — foco no app iOS/iPadOS.

- [x] **2. WidgetKit / Live Activity — já implementado (verificado 2026-07-10)**
  Item estava desatualizado: o target `EpubToMp3Widget` já existe em
  `ios/EpubToMp3/EpubToMp3Widget/` (home-screen widgets — `EpubToMp3Widget`,
  `NowPlayingWidget`, `ContinueReadingWidget`, `LibraryWidget` —, lock-screen
  `.accessoryCircular/Rectangular/Inline` via `NowPlayingLockScreenWidget`,
  e Live Activity de conversão via `ConversionLiveActivityWidget`), com
  App Group `group.com.pietrocode.epubtomp3` e sync em
  `EpubToMp3/Services/WidgetDataSync.swift`. Confirmado nesta passada:
  `xcodegen generate` → build Debug → install → launch no device físico
  (`00008140-001128A022BA801C`) sem erros, e os 9 testes de
  `WidgetDataSyncTests` passam no device. Nenhum código novo foi necessário.

- [ ] **3. Download/cache offline em disco não auditado recentemente**
  `offline-cache-mobile` (download manager, fila de transferência, eviction)
  é mencionado como escopo mas não há evidência recente de implementação
  completa — `ChapterCacheManager.prefetchNext` foi *removido* do
  auto-trigger (Bug 6 do bug sprint), mas não está claro se existe um
  fluxo explícito "baixar para ouvir offline" com fila/retomada.
  Verificar estado atual antes de agir.
  Agente sugerido: `offline-cache-mobile`.

- [ ] **4. Auditoria de acessibilidade (VoiceOver/Dynamic Type) pendente**
  Não há registro de uma passada recente do `ios-accessibility-auditor`
  neste app. Antes de qualquer release para TestFlight/App Store, validar
  VoiceOver labels/hints/traits nos controles de player e reader,
  Dynamic Type em XXXL (há comentários no código citando XXXL mas não
  confirma cobertura de VoiceOver), contraste de cor, reduce motion.
  Agente sugerido: `ios-accessibility-auditor`.

- [ ] **5. Auditoria de segurança / CVEs pendente**
  Último commit relevante de dependência é bump de rotina (dependabot).
  Não há registro de rodada completa de `security-auditor` (pip-audit +
  npm audit + CodeQL/Dependabot abertos + secrets no repo) recentemente.
  Rodar antes do próximo release.
  Agente sugerido: `security-auditor`.

- [ ] **6. (adicione aqui um item seu — bug relatado, feature pedida, etc.)**

- [ ] **7. (espaço livre)**

## Fora de escopo por ora

- Cliente Flutter (Android/Linux/Windows) — retomar quando priorizarmos multiplataforma.

## Prompt para o Claude

```
Resolva os itens marcados [ ] em TODO_APP.md, um de cada vez, na ordem em
que aparecem. Para cada item:

1. Se o item referenciar um agente sugerido, lance-o via Agent tool com um
   prompt específico e autocontido (não delegue "entenda e resolva" —
   escreva o contexto já levantado aqui).
2. Antes de codar, confirme o estado atual do repo (o item pode já estar
   parcialmente resolvido ou desatualizado — verifique antes de assumir).
3. Diagnostique a causa raiz (se for bug) ou desenhe o escopo mínimo
   (se for feature) antes de alterar código.
4. Implemente o fix/feature mínimo necessário — sem abstrações
   especulativas, sem gold-plating.
5. Adicione/atualize teste de regressão cobrindo o caso (obrigatório —
   ver Testing Policy do CLAUDE.md).
6. Rode a suíte relevante (`mise run test`, ou testes específicos da
   plataforma) e confirme verde antes de prosseguir.
7. Para mudanças iOS: build → install → launch no device físico e
   confirme visualmente antes de declarar resolvido (nunca declarar
   fixed só com base em compilação/testes unitários).
8. Faça commit focado (mensagem em inglês, foco no "porquê", não no "o quê").
9. Marque o item como [x] neste arquivo e adicione uma linha de status
   (data + hash do commit) logo abaixo dele.

Pare e pergunte se um item depender de decisão de produto/escopo que não
esteja clara neste arquivo (ex: qual plataforma priorizar no Flutter).
```
