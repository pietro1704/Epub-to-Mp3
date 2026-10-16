# App delivery backlog

## APP-20261016-EDGE-ADAPTATION-FIXTURES — Restore valid local Edge protocol fixtures

- [ ] Update both adaptive TTS WebSocket fixtures to emit length-prefixed `Path:audio`/`Content-Type:audio/mpeg` headers while preserving adaptive size, ordering, retry and cancellation assertions.
- Owner: Rust fixture specialist; isolated `feature/fix-edge-adaptation-fixtures`.
- Red evidence: GitHub CI run `38870071189` on `a87337fbc19f1901eddb6e4d5c6b1522f40b9c66` passed 149 core unit tests, 10 embedded-audio and 3 in-process-audio cases, then failed 7 of 8 adaptive TTS cases because obsolete zero-length fixture headers violated the production parser's required audio path.
- Acceptance: no production protocol relaxation; a real local WebSocket negative regression must still reject binary audio with a missing path. Verification/formatting runs only on GitHub; no local test, build, probe or formatter executed.

## CI-20261016-DESKTOP-AUDIO-PREREQUISITES — Preserve desktop codec coverage

- [ ] Owner: crash_workflow_audit; install explicit ffmpeg/ffprobe prerequisites before the Ruby/Rust integration suite. Keep the ADPCM sample-rate and validation assertions mandatory, with actionable failure diagnostics; preserve the isolated native-audio test with external tools disabled.
- Red evidence: GitHub Ruby Rust Integration run `38870071032`, head `a87337fbc1`, failed `unsupported_native_wave_codec_preserves_external_capability` at external `ffprobe` spawn with `Io(NotFound)`; the two other integration cases passed. This workflow omitted the desktop audio package already installed by the main Rust CI job.
- Acceptance pending: GitHub-only Ruby/Rust integration passes the unchanged ADPCM capability assertions and native isolation cases. No local tests, builds, formatter, syntax checks or audio tools were executed.


## APP-20261016-FFI-CANCEL-STATE — Persist controlled cancellation after cached playback

- [ ] Owner: crash_guard_audit; restore the valid `Running -> Cancelling -> Cancelled` sequence for control-token cancellation and propagate job-store failures instead of leaving a running record behind.
- [ ] Exercise token-only cancellation, an already durable cancellation request and a missing job record at the core seam. Seed the existing FFI priority/handle-release/cancellation tests through actual offline system-fixture conversion and verified receipts; assert replay performs no synthesis and preserves audio/receipt bytes.
- Red evidence: GitHub portability run `38870071388`, job `116871820752`, failed one of 18 FFI tests because persisted state was `running` rather than `cancelled`. The fixture also attempted Edge synthesis because raw WAV files lacked completion receipts. Source prepared; GitHub verification pending. No local tests, builds, formatters, syntax checks or native/device actions executed.

## APP-20261016-CI-LEGACY-GUARDS — Reconcile legacy guard regression contracts

- [ ] Owner: crash_guard_audit; acceptance: replace references to removed private resource APIs with the documented compatibility, lease and oldest-runtime selection contracts. Preserve canonical Ruby Intel quarantine independently in PR #804.
- [ ] Cover a real fixture child's held lease, literal argument identity, release after success/failure/spawn error, and preserved contention-holder record. Selector cases must use supplied JSON or mocked service failures, never a real Simulator.
- Evidence: master Actions run `38862909247`, Python job `116849117822`, reported nine stale guard/selector failures. Source changes prepared; GitHub-only execution pending. No local tests, syntax checks, native tools or devices were executed for this slice. External Edge HTTP 403 failures are a separate atomic task.

## CI-20261016-OFFLINE-AUDIO — Separate decoded-audio regressions from live Edge availability

- [ ] Replace implicit network audio fixtures with deterministic local PCM/MP3 checks covering real decoding, title/body pause, sample rate and retained active audio.
- [ ] Keep actual Edge synthesis behind explicit `RUN_LIVE_EDGE_AUDIO_TESTS=1`; HTTP 403, timeout and empty payload remain fatal in the manual-only GitHub live workflow.
- [ ] Verify default collection avoids network, disabled synthesis never imports/calls Edge, explicit opt-in is literal, and live provider errors propagate. Execute checks only on GitHub under the current user instruction.
- Owner: crash_workflow_audit specialist; branch `feature/ci-offline-audio-fixtures`. Baseline: master CI run `38862909247`, Python job `116849117822` has one Edge fingerprint failure and three audio-fixture setup errors from HTTP 403. No production/provider code changes or live provider probes.
- Status: implementation pending GitHub verification; no local tests or syntax checks executed. Preserve user books/models and unrelated work.
- Follow-up evidence: full GitHub CI `38867253856` passed Python tests and lint, then the legacy CLI smoke failed on live Edge HTTP 403. Default CLI and external-pool smokes now explicitly install checksum-pinned Faber medium into the disposable runner and synthesize offline with fallback disabled, separate outputs and fresh processing. Existing live Edge CLI/pool checks move to the explicit manual workflow; their provider failures remain fatal. No production provider or user model-install behavior changes.

## APP-20261016-CI-LIBRARY-ACTIONS — Exercise visible library actions

- [ ] Owner: crash_guard_audit; acceptance: scroll the selected book title into the hit-testable viewport before long-pressing, retain action assertions, and exercise localized tag-editor entry/dismissal without changing book identity or unsaved tags.
- Evidence: master Actions run `38862909247`, Flutter job `116849117924`, missed the gesture at `(77.3, 754.0)` outside its `800x600` viewport. This is a CI test interaction correction, not a claimed product UI fix. GitHub-only tests pending; no local Flutter tests, analysis, builds or devices executed.

## APP-20261016-RUST-EXECUTION-CONTRACT — Restore worker execution contracts

- [ ] Restore scoped cache refresh, forced transactional audio replacement, bounded performance options and pinned explicit Piper model identity without replacing current streaming/receipt behavior.
- Owner: Rust contract specialist; isolated `feature/restore-worker-execution-contract`.
- Red evidence: GitHub Actions master `915e9c` failed compiling `worker_execution_flags` and the server resume regression because production APIs/request fields diverged.
- Verification: GitHub-only Rust tests; local tests and native execution are suspended. Preserve cancellation, prior artifacts on failure and selected chapter boundaries.
- Formatting also runs only on GitHub. A read-only formatting-preview job retains the exact source SHA and a patch for source review; it cannot push or modify a PR. Existing CI still requires a clean formatting check.
- Run feature-branch full CI through PR events (including the synthetic merge revision), avoiding redundant source-only push runs. Preserve all PR checks and default/develop/release/hotfix push coverage with separate concurrency groups. Review and apply only Rust formatting output from GitHub; exclude unrelated LFS normalization from formatting patches.

## APP-20261016-MPEG-INTEGRITY — Validate segmented MPEG metadata and frame counts

- [ ] Reject whole-frame truncation against declared Info/Xing counts and exclude binary midstream ID3 payloads from audio decoding while preserving exact concatenated durations.
- Owner: Rust audio specialist; isolated `feature/fix-embedded-mpeg-integrity`.
- Red evidence: GitHub run `38864616556` passed 141 core unit tests but failed existing `embedded_audio` cases `child_explicit_mpeg_counts` (line 208, accepted missing frame) and `child_binary_midstream_id3` (line 247, incorrect summed duration).
- Follow-up red: GitHub run `38867253795` on integration `1750299` exposed fresh `rusty_mp3` output declaring metadata-inclusive frame totals. Normalize only typed finished-encoder output after checking actual packet sizes, physical frame totals and byte counts; keep foreign-input truncation checks strict. Both system PCM and Piper use the shared collector.
- Verification pending: unchanged existing fixtures/assertions plus focused bounded-stream/parser regressions on GitHub only. No local tests, builds, probes or formatter execution.

## CORE-20261016-SOURCE-TOTAL — Restore full-source chapter metadata

- [ ] Restore the optional `OutputManifest.source_chapters_total` contract from `68f8b12ad2`: emit the parsed book's full count before selection, while selected chapter counts and source indexes keep their existing meaning.
- [ ] Preserve legacy JSON decoding with unknown source total (`None`) and omit that absent field on serialization. Verify explicit counts round-trip and invalid negative counts fail.
- [ ] Verify actual selected-one-of-two conversion and persisted manifest metadata through the existing offline worker/receipt/archive regression; execute checks only on GitHub. Add the required optional fields to server test fixtures; keep the CLI fixture's meaningful `None` unchanged.
- Owner: crash_workflow_audit specialist; branch `feature/restore-manifest-source-total`. Status: implementation pending GitHub verification. Baseline: recovery CI `38867253856`, Rust job `116863046347`, reports CLI `E0560` at the orphan field initializer. No local tests/builds/formatter, root dirty worker edits, audio changes, journal resurrection or native-client/progressive-session claims.

## CI-20261016-CODEQL-APPLE — Restore real Apple source coverage

- [ ] Preserve the existing production macOS CodeQL category and restore the historical macOS unit, iOS unit and iOS UI compile categories with their real schemes.
- [ ] Build actual SDK-correct Rust FFI prerequisites before project generation; compile iOS app, ShareExtension and Widget through the production dependency graph. Use generic device destinations; no Simulator boot or fake empty dylibs.
- [ ] Verify all seven Swift analyses on GitHub, including real historical combined/platform-only app builds. Compilation and analysis are not app execution, native test success or proof of driver stability.
- Owner: crash_workflow_audit specialist; branch `feature/codeql-apple-coverage`. Status: source prepared; no local tests/builds/syntax or remote configuration mutations. Preserve unrelated macOS/other-language jobs and the strict merge gate.
- Baseline evidence: PR805 CodeQL check `116849734709` reported seven missing Swift configurations while its macOS Swift analysis was still pending. Three retired test categories last had successful master analyses on 2026-09-28. Current workflow omitted real UIKit/iOS extension extraction.
- GitHub master run `38862918459`, Swift job `116849100230`, completed its Swift build but exceeded the 40-minute job limit during TRAP finalization. Raise only that job budget to 90 minutes; preserve extraction, queries, coverage and single-job builds. Analysis success remains pending.
- Restore `/language:swift` with both macOS and iOS app builds in one traced database, and each platform-only category with its own actual app build. All uploads retain job identity `.github/workflows/codeql.yml:swift`; historical uploads use the exact original matrix environment, without filtering or relabeling unrelated coverage. Source evidence: successful master analyses `1620733555` (`78df918cf2`, combined, environment `{}`), `1621861648` (macOS) and `1621863231` (iOS), both platform analyses at `00073d5210`. The original/default query policy remains unchanged; no analyses, alerts or security configurations are deleted.
- Limit Swift matrix concurrency to two hosted runners after the observed Mac capacity warning; preserve single-job native compilation and the 90-minute per-job timeout. GitHub extraction, SARIF processing and configuration reconciliation remain unverified until their actual jobs finish.

## APP-20261015-WHOLE-IOS — Reviewed whole-app iOS 15 verification campaign

- [ ] IOS-ALL-1: persist the user's campaign preferences in canonical harness instructions and ai-memory before execution; obtain specialist plan review.
- [ ] IOS-ALL-2: verify whole-app journeys on iPhone SE (1st generation)/iOS15.5 with Xcode16.4, existing hooks/lease and strict build/Simulator phase separation.
- [ ] IOS-ALL-9: for each evidenced defect, isolate one branch/PR, verify the real corrected behavior, add meaningful native regression coverage, and merge to master only after required checks are green.
- [ ] IOS-ALL-10: verify the actual native macOS app separately; close iOS Simulator first and stop the Mac app whenever idle.
- [ ] IOS-ALL-11: after Apple verification, implement the corresponding Flutter slices on separate branches and verify actual Samsung/Android and Arch Linux app behavior; inspect Wayland/display availability without assuming support.
- User correction: always close the app, shut down its Simulator and quit Simulator.app when no longer actively used. Keep screenshots/reports rather than retaining an idle Simulator. Save confirmed lessons in canonical harness instructions and explicitly requested ai-memory notes.
- Owner: Codex root; specialists review safety/runtime, UI/state and conversion/Git isolation. No questions while the user is away; continue independent work and report user-dependent blockers at the end. Preserve all existing dirty changes, books, models and Simulator data.
- Plan, acceptance matrix, task ownership and evidence: `docs/plans/2026-10-15-ios-whole-app-verification.md`. Status: planning; no new app verification claimed.

Current user requirements override the historical backlog below. Workflow:
Pending → In progress → Verification → Done, or Blocked with evidence/next action.
Every concrete user request/correction belongs here. Completion requires relevant
tests, cross-platform parity, and commit/push evidence; source presence is not done.
Current ownership: native Apple development and verification happen on this Mac; authorized Flutter Linux and Android/Samsung work runs on Arch. The native Apple runtime requirement is authoritative in
`docs/agent-workflow.md`; entries here record task-specific criteria and evidence.
Historical Arch assignments below are superseded.

## Active requests — 2026-10-10

- [x] **APP-20261014-04 — Correct all native screens against Apple HIG on SE, Pro Max and Mac.** Verified and delivered in commit `77044c4058`, [PR #794](https://github.com/pietro1704/Epub-to-Mp3/pull/794). User confirmed navigation changes when necessary and sequential execution. Acceptance: inventory all screens/secondary states; responsive native controls, readable localized text, accessibility, light/dark appearance; actual SE/iOS15.5, Pro Max and Mac verification with reader/player invariants preserved. Plan: `.hermes/plans/2026-10-14-apple-ui-hig.md`. Verification: Mac 10 focused native tests and actual resized app; Pro Max 10 native tests and English/PT-BR GUI navigation; SE 10 native tests, English/PT-BR accessibility XXXL GUI and five real LOTR reader regressions passed. Final cell-traits regression plus forms/responsive tests passed 10/10 on SE; coverage limits and logs in plan.

- [x] **APP-20261014-03 — Consolidate all branches into master locally and remotely.** Done: master b247a86807 pushed; six local branches and five remaining remote branches removed only after ancestry checks. Live git ls-remote --heads origin and git branch both show only master. Preflight passed on the exact detached integration commit (the script rejects master by policy); product source identical to previously verified app branch. User explicitly authorizes integrating every branch and deleting branches already incorporated. Latest app branch fast-forwarded into master; remaining playback-documentation and tooling branches merged. Old playback-documentation conflicts resolved by preserving newer, more complete delivery records. Every local branch tip is an ancestor of master. Local .ai-jail and .ai-memory.toml preserved; tooling worktree will remain detached. Acceptance: pushed master contains all branch tips; only master exists in local branches and live remote heads.

- [x] **APP-20261014-02 — Use one Play/Pause control for reader playback choices.** Delivered in c3249a17, pushed on fix/single-reader-playback-control. Mac 21/21; SE 23/23 native + 2/2 GUI; LOTR 1/1 passed. Full PT-BR choices visually confirmed on 320-point SE. Original reader state restored; normal SE app open. Supersedes APP-20261014-01's separate current-page button: remove it on iOS/macOS. Playing Play/Pause only pauses; after page movement, paused Play offers exactly Continue where I left off / Listen from this page / Cancel using large native actions. Unchanged-page Play resumes immediately. Cancel preserves paused cursor. Verify exact SE/iOS15.5 and macOS, preserve reader geometry/providers/downloads, commit/push. Plan: docs/plans/2026-10-14-single-playback-control.md.

- [x] **APP-20261014-01 — Choose playback from the newly visible reader page.** Verification: exact SE 68/68 native and 2/2 actual GUI passed; Mac 64/64 runtime plus final 3/3 native control/handoff passed. Delivered as b0186420eb and pushed on fix/reader-page-playback-choice. User authorizes commit/push of prior verified app work and this correction. Acceptance: turning pages must not silently move ongoing audio; while playing, expose an explicit action to play the current page. After page movement while paused or playing, paused Play offers current page versus continuing the existing audio cursor. No page movement preserves ordinary pause/resume. Same-chapter and streamed audio are included. Preserve reader geometry, Edge/provider policy, downloads and remote transport. Verify exact SE/iOS15.5 and native macOS, then commit/push. Plan: `docs/plans/2026-10-14-reader-page-playback-choice.md`.

- [x] **APP-20261013-07 — Finish streaming, downloads and transport controls on the exact iPhone SE Simulator.** Delivered in c30ae5a7e0, pushed on feature/native-tts-fallback (master integration 8c5267535e). Tested actual app before corrections; fixed eight reproduced app errors. Exact SE/iOS15.5/Xcode16.4: fresh Edge first audio 1.900 s (GUI observation 4.103 s), pause/resume, next/previous preserving pause, skips/scrubber, actual 1.5x rate, two retained Edge MP3s and replay after relaunch passed. Final GUI 2/2, focused macOS parity 16/16, LOTR pagination/chrome 1/1 with clippedLineCount=0; native regressions and timer actions passed. Original reader state restored; only exact SE normal app remains open on LOTR. Existing worktree preserved; changes local. Full error list, plan and evidence: `docs/plans/2026-10-13-se-streaming-controls.md`.

- [ ] **APP-20261013-06 — Verify real iPhone 16e streaming, downloads and playback controls; fix observed errors.** Blocked on user unlock after initial readiness passed; the phone auto-locked before build/install/test. Focused runtime coverage and fresh two-chapter fixture prepared, scoped whitespace checks pass; physical behavior remains unverified. Evidence: `.reports/device/30D81C82-F0E5-4803-BDAD-52FF43F8513B/report.json`. User explicitly authorizes physical-device app tests and execution through the error list using goal-plan-execute. Acceptance: fresh Edge-first audio with measured first-playback latency, progressive playback before conversion completion, playable persisted download, responsive pause/resume and next/previous controls on the actual iPhone 16e. Record every observed failure and retest minimal fixes; preserve working flows and existing books/audio. Device readiness, missing coverage and runtime blockers must be reported separately from app errors. Plan: `docs/plans/2026-10-13-iphone16e-streaming-controls.md`.

- [x] **APP-20261013-05 — Preserve working app behavior.** Persisted the user's correction in `CLAUDE.md` (shared through the root `AGENTS.md` symlink): limit changes to the current request, preserve working flows, and revisit resolved areas only when concrete evidence requires it. Verification: instruction read-back and scoped `git diff --check` passed. Documentation only; no app runtime changes or builds.

- [ ] **APP-20261013-04 — Implement free Edge-first native speech fallback.** Verification; local implementation and available checks passed, Android device runtime and clean task-only delivery pending. User authorized the proposed app behavior: Edge online, installed native offline voice on Edge/network failure, short first audio segment, bounded progressive generation/cache, and visible voice-change notice. Suspend Piper in app choices; no paid providers or implicit model downloads. Rust retains provider policy, chunk ordering, WAV-to-MP3 validation, artifacts, cancellation and playback window. Implement Apple AVSpeechSynthesizer and Android TextToSpeech adapters. Acceptance: failed Edge segment continues once through native voice without replaying prior text; cancellation/window change never triggers fallback; missing local locale reports an actionable error; output is playable MP3; cached fallback is not mislabeled Edge; native iOS SE/iOS15.5 and macOS checks, Rust tests and Android build/tests, with absent physical Android runtime reported. Preserve all prior local changes. Plan: `docs/plans/2026-10-13-native-tts-fallback.md`.

- APP-20261013-04 superseding user correction: local/Siri TTS misreads too much and must be occasional fallback for isolated segments. Retry Edge on every next segment. Stop after two consecutive failed Edge segments rather than automatically narrating the book with the local voice. Invalidate the former book-wide fallback cache policy and make notices describe a temporary segment substitution. Explicit system-engine fixtures are verification only; the product offers Edge.

- [ ] **APP-20261013-04-EDGE-PRIMARY — Prove normal Listen uses Edge instead of silently accepting native speech.** Verification: strict actual playback passed 1/1 each on iOS15.5 and macOS, with no system provider or direct speech transport; normal SE app GUI left open and seeded EPUB language verified as en. Local test changes await task-only delivery. User heard Portuguese local voice from this Mac while native verification was active and could not identify CLI/app/Simulator. Keep the exact Simulator GUI visible and leave the normal app open after checks. Tighten actual Listen/player golden tests to reject any system-provider progress or direct speech fallback before first audio and after final conversion. Separate deliberate native fixtures from primary playback; verify actual provider and book language without changing saved reading state.

- [ ] **APP-20261013-04-ANDROID-STREAM — Deliver first MP3 bytes before Android chapter completion.** Verification: implemented; 55 Flutter tests pass, 7 JVM results reused, analysis clean, actual arm64 JNI and final APK built/checked. Physical Android playback remains pending. Acceptance: request-scoped JNI chunk events published after atomic file writes; subscribe before native conversion; one growing player source per chapter, first bytes available before final result; completion preserves queue/index/position; unavailable-range seeks wait without false EOF; cancellation/window changes reject late chunks and stop the exact request. Preserve whole-book conversion. Permanent Dart source/channel/window regressions and current arm64 JNI/APK verification; actual Android playback/weak-phone timing remains unverified without a connected device.

- APP-20261013-03 user correction: fallback candidates must be free of paid SDK/API requirements. Exclude Orca, ReadSpeaker, Acapela and CereProc from the recommended shortlist; retain them only as historical research context. Proposed direction: Edge primary, installed offline platform TTS first for evaluation, compact free engines as optional research candidates. This is a recommendation, not authorization to implement or automatically switch providers.

- [ ] **APP-20261013-03 — Keep Edge active and investigate speed-first TTS fallbacks for weak devices.** Verification; physical mobile benchmark pending. User correction: do not use Piper for now; use Edge. Piper native playback verification is deferred, not the next delivery gate. Research the practical TTS model/engine landscape using primary sources, including Portuguese, offline/platform support, memory, licensing, and published hardware-specific benchmarks. Execute comparable benchmarks for locally available non-Python runtimes where feasible; report unavailable models and mobile hardware honestly. Acceptance: evidence-backed fallback recommendation prioritizing first playable audio, sustained throughput, and weak-phone resource cost; distinguish local measurements from published claims. No automatic engine switch or physical-device actions are authorized by this research request. Evidence: `docs/research/2026-10-13-speed-first-tts-fallback.md` and companion primary-source inventories. `mise exec -- ruby docs/research/tts-host-benchmark.rb` passed 12/12 same-text host runs (Apple Luciana versus Rust Edge Francisca), all MP3s fully decoded by ffmpeg; separate signal audit found peaks -4.1 to -2.6 dB. Paragraph medians: 1.355 s Apple, 2.267 s Edge; short: 0.791 s / 1.905 s. Hardware is Intel i5-8259U/8 GiB Mac, not a weak phone; TTFA/battery/thermals were not measured. Ruby syntax, JSON read-back and whitespace checks pass. Edge defaults and existing user preferences were not changed; no Piper execution, app build, device interaction, new model download or commit/push. Published ARM/mobile evidence favors evaluating platform TTS and compact engines before assuming a universal neural winner. Full cross-model weak-phone acceptance remains open.

- [x] **APP-20261013-02 — Automate Matt skill routing, execution prompts, and optional goals.** Updated and installed `auto-prompt-execute` in the repository and global skill directory. It recovers live context, consults `ask-matt`, loads selected available skills, writes and executes the prompt in the same session, and manages explicitly authorized goals when useful. Verification: Ruby YAML metadata validation passed, installed copies match via `cmp`, full body/UI read-back and scoped whitespace checks passed. No native app changes or runtime checks; the Python skill validator was skipped under the repository's local Python policy. Behavioral quality across future product tasks remains unmeasured.

- [ ] **APP-20261013-01 — Default Apple playback to Edge; allow Piper only by explicit saved preference and repair its native playback path.** In progress. User asked to fix Piper playback, make Edge the playback engine by default, and use Piper only when switched to the local model in settings. Acceptance: persisted Edge-default engine setting on iOS/macOS; Listen and manual conversion use the selected engine; FFI passes that engine through both streaming and whole-book paths; Piper is not silently selected or substituted; Piper audio reaches a playable MP3 artifact on supported Apple targets or reports a precise unsupported-runtime error. Compare Edge/Piper speed with current primary-source research and representative local timing where both can run. Verify macOS and the exact iPhone SE (1st generation) / iOS 15.5 Simulator, including explicit Piper selection behavior. Preserve unrelated worktree changes. Current evidence: Swift Settings persists Edge by default; Listen, reader streaming, manual conversion and whole-book conversion pass the saved selection to Rust. The FFI passes the installed Piper model and voice-config paths per conversion; Piper remains explicit. Intel UI hides Piper where ONNX Runtime has no x86_64 macOS/iOS distribution; FFI rejects unsupported x86_64 iOS selection and rejects missing model/config. Piper's WAV-to-MP3 step now uses bundled pure-Rust `rusty_mp3` (96 kbps), decodes its output in-process, and atomically publishes only a valid file. Six focused Piper unit tests pass; a non-silent 440 Hz WAV fixture at the installed Piper model's 22.05 kHz rate produced an MP3 with nonzero decoded samples, `ffprobe` identified mono MP3/22.05 kHz, and independent `ffmpeg` fully decoded it. iOS arm64 Release FFI rebuilt with Piper after fixing the Apple cross-compile toolchain; current Mach-O verification reports arm64/iOS, minimum iOS 15.0. The exact iPhone SE (1st generation)/iOS 15.5 app launch and Edge-default/explicit-Piper Settings XCTest passed earlier. macOS Debug app build/run and focused settings tests passed earlier. `git diff --check` passed. Runtime limits: the iOS 15.5 Simulator is x86_64 and cannot run Piper's ONNX runtime; no arm64 device playback is evidenced. The Mac's Python ONNX Runtime is 1.23.2 while `ort` requires API 1.24; dynamic-loader probes hang while handling that incompatibility. The static Piper runtime build also confirms `ort-sys` provides no prebuilt `x86_64-apple-darwin` binary. These are diagnostic host limits, not evidence of playback failure on supported arm64 Apple targets. Edge service production conversion and an independent `edge-tts` probe both receive HTTP 403 from the Microsoft endpoint; no Edge audio or comparable speed measurement exists. Previously measured local Piper CLI timing was 1.62–2.03 s for 4.16 s speech; it predates the embedded path and does not establish current relative speed. Keep open until Edge audio playback and a valid apples-to-apples speed comparison can be verified.
  Superseding user correction, 2026-10-13 (APP-20261013-03): use Edge for now; defer Piper native playback work. Investigate speed-first fallbacks for weak devices before selecting any alternative. Earlier Piper verification gates below are historical and are not the next requested action.
  User correction, 2026-10-13: iOS verification for this task must use the iPhone SE (1st generation) Simulator on iOS 15.5 through Xcode 16.4 (`/Applications/Xcode-16.4.0.app`); do not substitute the physical iPhone or Xcode 26.
  Piper continuation, 2026-10-13: current `mise run converter-ffi:ios-device` rebuilt `target/aarch64-apple-ios/release/libconverter_ffi.dylib` with `piper-runtime`; `mise run converter-ffi:ios-device:verify` confirms arm64/iOS and `vtool` reports minimum iOS 15.0; `nm` confirms `_piper_runtime_register_embedded`. A clean build first found host `ring` C compilation lacked the macOS SDK; fixed the task to pass Xcode macOS clang/sysroot to host helpers while preserving iPhoneOS SDK flags for arm64. Re-running the task with no extra host env succeeded (incremental 19.87 s). `mise exec -- cargo test -p converter-core --lib piper::tests` passes 6/6; `mise exec -- cargo test -p converter-ffi --lib piper` passes 2/2. This verifies encoder/FFI contracts and the arm64 iOS artifact, not Piper model inference/playback. The required visible Simulator remains the only open native app/runtime; no iPhone 16e install or launch occurred. Keep the task open for runtime inference/playback on compatible arm64 Apple hardware.
  Live iOS Simulator verification, 2026-10-13: added opt-in tests through the actual iOS Book Detail actions and bundled x86_64 Simulator FFI. `APP_IOS_LIVE_EDGE=1` is explicitly forwarded by the iOS Xcode scheme test action. On exact Xcode 16.4 / iPhone SE (1st generation) / iOS 15.5, `mise run ios:simulator:test` with filters for BookDetailManualConversionTests, actual Piper FFI rejection and Edge preference passed 9/9, zero failures/skips; result `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-58-08--0300.xcresult`. The live Listen test held the first accepted Edge audio callback while asserting AudioPlayer had its first segment, was playing, AVQueuePlayer was ready and its playback clock advanced before conversion returned. The live manual Convert test invoked the whole-book action through the same Swift coordinator/FFI, checked Edge selection and chapter range -1…-1, validated a nonempty MP3 and ZIP from the manifest, confirmed the library recorded the job, and verified no playback session/autoplay. The FFI rejected explicit Piper before accessing the EPUB/output; Settings retained Edge default. Reinstalled/launched normal app and left visible Simulator foregrounded; screenshot `/tmp/epubtomp3-edge-piper-ios15-current.png`. This establishes live Edge playback and manual conversion on iOS Simulator. Piper inference remains unavailable on this Intel/x86_64 simulator and requires an arm64 Apple runtime for runtime verification.
  Follow-up local engine probe, 2026-10-13: the Rust `embedded_edge_probe` succeeded against the live Edge service and wrote `/tmp/edge-probe-current.mp3`; independent `ffprobe` confirmed mono MP3/24 kHz, 4.08 s. For the same Portuguese sentence, Edge returned 24,480 bytes in 1.238 s (RTF 0.30). The installed Piper Python CLI/model produced a WAV of 3.39 s in 1.57 s (RTF 0.46, cold process). On this single short sample Edge was faster end-to-end. This is directional only: CLI cold-start vs network request, different voice/model and encodings, and not embedded Apple Piper inference. Separately, isolated Rust manual conversion with explicit Piper on `web/public/sample.epub` chapter 0 passed `--verify`, producing a 348 KiB mono MP3/22.05 kHz, 29.75 s plus ZIP; `ffmpeg` fully decoded the MP3. This verifies host CLI Piper routing/encoding, not native app inference. No app source changed in this follow-up. The Simulator remained on exact iPhone SE 1st generation/iOS 15.5 via Xcode 16.4; iPhone 16e was not used.
  Follow-up Simulator run: the first combined Book Detail suite exposed that its asynchronous-open case used a synthetic EPUB with no readable chapter and let real Edge networking contaminate an opening-only test. Replaced that fixture with a readable chapter and injected a controlled streaming executor. Isolated case passes 1/1 (`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-49-52--0300.xcresult`); the combined Book Detail, explicit Piper FFI rejection and Edge preference run passes 7/7 (`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-50-23--0300.xcresult`). Exact Xcode 16.4 / iPhone SE (1st generation) / iOS 15.5 destination. GUI Simulator was activated visibly in foreground; current app installed/launched and screenshot saved to `/tmp/epubtomp3-edge-piper-ios15-current.png`; no Mac app or iPhone 16e app ran. This verifies native iOS routing/preference/manual behavior with controlled executors and actual FFI unsupported-runtime handling; it does not establish live Edge service audio delivery through iOS UI.
  Latest correction and verification, 2026-10-13: iOS testing is Simulator-only on Xcode 16.4.0 and the exact iPhone SE (1st generation)/iOS 15.5. The earlier physical-device/Xcode 26 detour was incorrect; no physical-device install or app launch occurred. Xcode 16.4 built the current iOS Simulator app after the host-side FFI build script stopped inheriting the iOS `SDKROOT`. Four focused XCTest cases passed (Edge default/Piper preference persistence, Piper model-readiness guard, manual conversion without autoplay, and progressive chapter playback before conversion completion), zero failures, result `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-09-09--0300.xcresult`. The actual app was installed/launched on that Simulator with development seeding disabled; screenshot `/tmp/epubtomp3-edge-piper-ios15-current.png` shows the retained LOTR Contents page. Only this Simulator/app is left open. Simulator tests verify preference/routing contracts; Piper ONNX inference is not supported by this x86_64 Simulator and remains unverified on an Apple arm64 target.
  User correction, 2026-10-13: use Xcode 16.4 with the iPhone SE (1st generation) / iOS 15.5 Simulator, and run only one native app/Simulator target at a time; stop and verify the previous target before switching. Latest exact-target regression: 3 focused XCTest cases passed (3/3, zero failures), including actual Swift FFI rejection of explicit Piper before EPUB/output access, Piper readiness guard, and Edge default/preference policy. Result: `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-40-53--0300.xcresult`. The host is Intel x86_64. The FFI reports `Piper requires an arm64 iOS runtime; select Edge on this simulator.` No inference or speed claim is made for this Simulator.
  Follow-up verification, 2026-10-13: found the iOS Book Detail Listen action still called whole-book `conversionExecutor`, unlike the Mac detail and reader streaming routes. It now installs a pending player session, requests streaming from the saved priority chapter onward with a one-chapter playback window, forwards progress/completed chapters/audio chunks into the existing player, and finalizes or reports conversion errors; Download remains on whole-book conversion. Regression result: `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-28-24--0300.xcresult`, 13 focused tests passed (Book Detail streaming route; manual completion without autoplay and with session preservation; 8 progressive-listening tests; Edge default/persistence; Piper model readiness). The app is installed and open on the exact SE 1st generation/iOS 15.5 Simulator with Xcode 16.4; screenshot `/tmp/epubtomp3-edge-piper-ios15-current.png` shows the LOTR Contents reader. `git diff --check` passes. A new regression test caught the missing route before the fix; the green run verifies routing/session setup, while actual live Edge audio delivery remains covered by prior Mac production-FFI evidence, not this Simulator fixture. Piper inference on arm64 hardware and an apples-to-apples Edge/Piper speed run remain open.
  Listen lifecycle follow-up, 2026-10-13: chapter changes now move the Rust playback window and reprioritize the active chapter; repeated taps are ignored while the EPUB URL opens; the full player is presented once when the first stream segment is accepted; errors only present an alert when Book Detail is visible. Exact Xcode 16.4 / iPhone SE (1st generation) / iOS 15.5 Simulator regression run passed 4/4 (streaming route, duplicate-tap suppression, manual no-autoplay, preservation of existing playback), result `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-2026.10.13_14-34-11--0300.xcresult`. Earlier same-turn run passed 14/14 across these routes, 8 progressive playback tests, Edge preference, and Piper readiness. App was reinstalled/launched on the requested Simulator; `/tmp/epubtomp3-edge-piper-ios15-current.png` shows the retained LOTR Contents screen. Only the exact Simulator and app are left open; no Mac app is open. `git diff --check` passes. Simulator coverage verifies route/session setup; a real live Edge service session through this iOS Detail screen and Piper inference on supported arm64 Apple hardware remain unverified.
  Superseding live verification, 2026-10-13: found and fixed the actual scoped-listen failure. Swift FFI encodes chapter selection as `position:N`, but the Rust worker only parsed raw numbers or chapter IDs, so selected playback failed with “selected chapters have no readable text” before synthesis. Rust now parses the position prefix; its focused regression passes. The same production Swift coordinator and freshly rebuilt host Rust FFI then passed both live Edge paths (24/24 Foundation tests): streaming Listen returned one audio chunk and a 33,264-byte MP3; whole-book Convert, without playback control/callback, created a 30,096-byte MP3 and 30,230-byte ZIP. A native macOS XCTest using that same Rust dylib sent live Edge audio through `StreamingPlaybackChunkDelivery` into the app's `AudioPlayer`, confirmed AVQueuePlayer time advanced while the Rust callback was deliberately held and conversion had not returned: 1 passed, 0 failed/skipped (`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_11-27-37--0300.xcresult`). The official Debug build passed and `mise run mac:run` relaunched the app (PID 72394); the app window is open on the retained library. `AudioEnginePreference` was extracted to a Foundation-only source shared by app and host integration tests; XcodeGen project sources include it, and the macOS scheme keeps the live-test opt-in configurable. Edge Listen and full-book conversion are now runtime-verified on Mac, not blocked by HTTP 403. Remaining acceptance: rerun applicable tests on exact iPhone SE/iOS 15.5 if its Xcode destination becomes eligible; exercise Piper inference on supported arm64 Apple hardware; and complete representative relative speed measurements before declaring a universal winner. Current same-text warm Piper inference was timed after model load: 0.141–0.241 s for 3.286–3.425 s of speech (RTF 0.041–0.073), materially faster than realtime locally. Piper CLI cold process runs took 1.408–2.264 s for ~3.2–3.3 s speech. Edge production FFI earlier completed a 3.36 s sample in 1.344 s total. These runs differ in startup, transport, and encoding; they do not establish an apples-to-apples winner or embedded Apple Piper performance. Speed probe uses the upstream Piper benchmark method of timing synthesis separately from model loading (rhasspy/piper PR #730). The earlier 403 and empty-artifact evidence below records the prior protocol state and is superseded by this verification. Current paired iPhone 16e reports `unavailable`. The exact iPhone SE (1st generation)/iOS 15.5 runtime is installed and booted (UDID `C66CCB36-C43E-4174-861E-2FA713389C84`), but Xcode 26.3 reports every app scheme ineligible because the iOS 26.2 platform SDK is not installed; `mise run ios:build` stops in its preflight before compiling, so no stale simulator build was installed as a substitute. A direct `xcodebuild ... -destination id=C66CCB36-C43E-4174-861E-2FA713389C84 build` confirms Xcode itself omits the booted 15.5 Simulator from destinations while iOS 26.2 platform components are absent.
  Latest native Mac run on 2026-10-13 passed the real streaming player bridge and Mac Book Detail Listen route tests 2/2 on My Mac/macOS 15.8.1 (`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_11-07-19--0300.xcresult`). A valid synthetic MP3 advanced AVQueuePlayer time; Book Detail Listen selected Edge, supplied the streaming callback, and did not invoke whole-book conversion. This proves route/player integration with fixture audio, not audible hardware output or live Edge app delivery. Edge migration is implemented in Rust: Read Aloud host `api.msedgeservices.com` and `Ocp-Apim-Subscription-Key`. Twenty-one protocol tests pass; actual Rust synthesis produced a decodable 20,160-byte, 3.360-second MP3 in 1.344 seconds. A same-text Piper CLI sample took 1.62 seconds and produced 2.612 seconds WAV; engines/voices/formats differ and this single timing is not a valid winner comparison. Current upstream endpoint migration was corroborated by edge-tts issue #490 (opened Oct 10, 2026) and the Readest client. The iOS 15.5 exact Simulator is booted and real app is open on retained LOTR Contents, but Xcode 26.3 marks all iOS destinations ineligible because iOS 26.2 platform is missing. The Intel Mac FFI excludes Piper ONNX runtime; the previous arm64/iOS Release FFI contains `_piper_runtime_register_embedded` and has minimum iOS 15.0, but no available arm64 iPhone can exercise inference. FFI lifecycle review confirms explicit Piper registration or precise unavailable-runtime result; no registration defect remains. The model install publication bug is fixed; 10 model-store tests pass and catalog install of `pt_BR-edresson-low` completed in an auto-cleaned temporary directory. Six Piper MP3 encoder tests pass. Keep open for legacy-simulator tests, live in-app Edge playback and full-book Convert, supported arm64 Piper inference, and a representative Edge/Piper speed comparison.

- Latest APP-20261013-01 verification, 2026-10-13: exact iOS 15.5 Simulator Settings test confirms Edge default and avoids persisting unsupported Piper on x86; it does not exercise choosing Piper on a supported arm64 device. The iOS device-target FFI build and Simulator app build both passed. Edge streaming, full-book conversion and actual AVQueuePlayer delivery passed live with the rebuilt current host dylib, so this supersedes the earlier HTTP 403 reports and stale-library failure. Same-text timing on this Intel Mac: warm Piper inference after model load took 0.404–0.569 s for 10.101–10.263 s of speech (RTF 0.040–0.056); Edge took 1.676 s end-to-end and emitted a decodable 12.552 s MP3 (RTF 0.134, includes network/setup). This run is not an Apple embedded Piper benchmark; it indicates local Piper inference is faster on this host, while the requested app default remains Edge. Piper RTF method matches the upstream benchmark script ([rhasspy/piper benchmark](https://github.com/rhasspy/piper/pull/730/files)). Updated Piper codec fixture to the installed model's 22.05 kHz rate; `cargo test -p converter-core --lib piper::tests` passes 6/6 and confirms non-silent decoded MP3 plus ffprobe/ffmpeg compatibility. Full crate integration compilation remains unavailable because the committed `worker_execution_flags` test references missing worker APIs (`ExecutionOptions`, `PreparedPiperModel`); it is outside the Piper unit target. Unsupported-runtime Piper inference remains unexercised on arm64 Apple hardware because the paired iPhone is unavailable and this Intel Mac/iOS 15.5 Simulator lack the embedded ONNX runtime; keep APP-20261013-01 open for that device-level check.
- APP-20261013-01 follow-up: `mise run converter-ffi:ios-device` rebuilt the current Piper-enabled release for `aarch64-apple-ios`; `mise run converter-ffi:ios-device:verify` confirms the output is arm64/iOS. FFI contract tests pass 2/2 for Edge default, explicit Piper selection, and required installed model/config (`cargo test -p converter-ffi --lib piper`). The paired iPhone 16e is connected but remains locked (`passcodeRequired: true`), so no installation, model download, preference change, or device playback was attempted. The host embedded-runtime smoke test was attempted and fails before inference because `ort-sys` has no prebuilt `x86_64-apple-darwin` binary. Thus the earlier “paired iPhone unavailable” state is superseded by “paired device present but locked”; actual Piper inference/playback on supported Apple hardware remains open pending an unlocked device. `git diff --check` passes.
- [x] **APP-20261012-02 — Verify Edge playback, progressive Listen, manual conversion, and Mac reader page.** Verified 2026-10-13; historical 403 results below were superseded by successful live production FFI runs.
  Final evidence: freshly rebuilt host FFI passed the production Edge streaming and whole-book conversion XTests 2/2 through `mise run apple:foundation:test`; streaming produced one 33,264-byte MP3 chunk and whole-book conversion produced a 30,096-byte MP3 plus 30,230-byte ZIP. A native macOS player XCTest passed with live Edge MP3: `AVQueuePlayer` reached `.readyToPlay`, its playback clock advanced, and conversion was still held inside the accepted first-chunk callback (`ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_12-08-12--0300.xcresult`). `mise run mac:run` rebuilt and launched the native app. The actual LOTR Mac boundary test passed 1/1; the exact iPhone SE (1st generation)/iOS 15.5 Simulator LOTR pagination/chrome test passed 1/1, and the app was relaunched and left open on LOTR Contents (`/tmp/epub-ios-lotr-final.png`).
  User explicitly requested execution of all four checks on the EPUB app. Reproduce
  Edge-backed Listen in the native macOS app and confirm audible playback begins
  from delivered audio before the requested conversion finishes; exercise the
  correct Mac Book Detail Listen to deliver Rust audio chunks progressively while
  keeping Convert as a separate whole-book action without autoplay; inspect the
  currently displayed LOTR reader page and chapter boundary. Preserve
  existing books, playback state, downloads, and all pre-existing worktree changes.
  Verify native macOS and the exact iPhone SE (1st generation) / iOS 15.5 Simulator
  for reader behavior. Evidence: Mac LOTR boundary XCTest passed 1/1 on 2026-10-13 against the imported LOTR EPUB (actual long adjacent chapters; backward/forward transition; final glyph inside visible document rect), result `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_11-34-20--0300.xcresult`. The current Mac app was relaunched from the official Debug build, and the LOTR card opened in the live app; screenshot `/tmp/epubtomp3-lotr-detail.png` shows the reader displaying “Chapter 1 Many Meetings” and rendered chapter text. The reader remains open. Opening it updated only the intended current-reading book to LOTR. Earlier six seeded LOTR UI tests passed on exact Simulator with `clippedLineCount=0` on initial and advanced pages; that older app was not rebuilt from current sources. The manual
  no-autoplay/session-preservation tests passed. Rust parsed
  `web/public/sample.epub` as two text chapters. Bounded live Edge attempts
  attempted the first text request (the `dispatching chunk` byte counts were
  UTF-8 text sizes, not audio); the hand-written client returned
  `Edge request throttled (HTTP 403)` before any audio-frame telemetry or completed
  chapter artifact. An independent `edge-tts-rust` probe also received HTTP 403
  (`x-msedge-ref` region GRU), while the public voices-list endpoint returned
  HTTP 200. Local UTC matched the Edge host Date within seconds, and the Rust
  Sec-MS-GEC version matches current upstream. Aligned the WebSocket handshake
  with upstream WSS headers by preserving `protocol_request` headers and removing
  extra HTTP navigation headers; changed `speech.config` metadata flags to the
  string values used by the reference protocol. All 13 focused Rust TTS protocol
  tests pass. After waiting beyond the 5-minute token bucket, a one-chapter live
  synthesis still returned HTTP 403; the independent client also gets 403. No
  successful Edge audio delivery is proven. Full-book synthesis through Edge was
  not completed. Fixed the Mac detail Listen
  route to use Rust streaming callbacks and deliver chunks to AudioPlayer; Convert
  still uses the non-streaming full-book executor and does not autoplay. Regression
  tests cover route selection, chunk acceptance/player start, and manual-session
  isolation. After the protocol adjustments, `mise run mac:run` rebuilt and
  launched the app (PID 32204). Focused Mac XCTest:
  `.build/Logs/Test/Test-EpubToMp3Mac-2026.10.12_22-34-21--0300.xcresult`:
  6 passed, 0 failed, 0 skipped. Runtime evidence still does not prove live Edge
  playback or Edge-backed full-book synthesis; keep this pending. Binary-frame
  parsing now validates `Path:audio`, accepted MPEG content type, and the empty
  terminal frame shape from the protocol reference; non-audio binary controls
  are rejected. Focused Rust protocol tests now pass 14/14 and `git diff --check`
  passes. Added HTTP CONNECT proxy support via `EDGE_PROXY`, `HTTPS_PROXY`, or
  `ALL_PROXY` (with `NO_PROXY` bypass); proxy credentials in the URL are rejected
  and TLS remains end-to-end to Edge. The local proxy tunnel tests pass. HTTP 403
  is now classified as a permanent Edge rejection, includes `x-msedge-ref` when
  available, and is not retried; 429/503 remain throttled/retryable. The focused
  tests assert a 403 performs exactly one request. The Mac Debug app rebuilt and
  relaunched successfully (PID 43419). This does not
  address the direct-route HTTP 403; no proxy or service credentials were found
  in local environment/configuration. Retried through the production Rust
  CLI using fixture chapter `0`, `pt-BR-FranciscaNeural`, and isolated temporary
  output/cache roots: it dispatched one 608-byte text chunk and then failed with
  `Edge request throttled (HTTP 403)`; job state is `failed`, and the output
  directory contains no audio artifact. The one-time invalid chapter-selector
  probe failed before network access and did not alter the EPUB. Separately
  verified whole-book conversion through the production Rust CLI with the locally
  installed Piper executable/model: `--verify` passed for both fixture chapters,
  emitted two nonempty MP3s (361,787 and 227,309 bytes) and a ZIP (589,406 bytes),
  and `ffprobe` decoded both as mono MP3 audio (22.05 kHz; 30.058 s and 18.855 s).
  Outputs and cache were isolated under `/tmp/epub-manual-check.gaSZGw`; this
  proves Rust manual conversion with Piper, not the Mac Book Detail action or
  Edge-backed manual synthesis. Focused Rust protocol tests now pass 17/17,
  including proxy CONNECT acceptance/rejection and `NO_PROXY` matching;
  formatting and `git diff --check` pass; focused Rust TTS protocol suite is now
  19/19. Next action: configure an approved
  `EDGE_PROXY=http://host:port` route in the macOS app process, activate an
  approved VPN, or provide authorized speech-service credentials. Then rerun
  Mac Book Detail Listen and whole-book Convert and verify audio frames/playback.
  On 2026-10-13, a single CLI request using the new fast-fail path dispatched
  that same first text chunk and returned `Edge denied the speech request (HTTP
  403)` without retry. Edge reference: `Ref B: SAO31EDGE0308`, timestamp
  `2026-10-13T12:04:35Z`. The isolated job is `failed` and its output folder is
  empty; no `AudioFrame` event or audio artifact was produced.
  Current native Mac regression run on 2026-10-13 passed 4/4 tests on `My Mac`
  / macOS 15.8.1: `BookDetailManualConversionTests` (3 tests) and
  `StreamingPlaybackChunkDeliveryTests` (1 test). Result bundle:
  `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_09-06-43--0300.xcresult`.
  These tests use injected conversion executors and a synthetic MP3 segment; they
  prove the Book Detail routing/manual isolation and player bridge contract, not
  audible Edge playback or a live full-book Mac conversion.
  Compared the handshake recovery with upstream `edge-tts`: HTTP 403 may carry a
  server `Date` header used to correct the `Sec-MS-GEC` clock token. Rust now reads
  that header, validates it as RFC 2822 within a 24-hour bound, applies the offset
  to both the token and speech timestamps, and makes one immediate clock-adjusted
  retry. A 403 without a valid Date remains fail-fast. Focused Rust TTS tests pass
  20/20, including one-retry and no-Date cases. A single live CLI request after
  this change still failed with HTTP 403 (`Ref B: SAO31EDGE0909`, `Ref C:
  2026-10-13T12:10:09Z`); the isolated output directory was empty. Mac Debug rebuilt
  and relaunched with this code (PID 44573). The Edge route remains unverified for
  audio delivery.

- [x] **APP-20261012-01 — Make the iOS reader Back control return to the library.**
  Fixed a UserDefaults fallback loop: `removeObject` exposed a lower-priority
  book ID, and the reader's missing-book observer repeatedly cleared that value
  on every defaults notification. Clearing now writes an empty override only
  when a fallback reappears and is idempotent. A regression test covers repeated
  clears. On the exact iPhone SE (1st generation)/iOS 15.5 Simulator, Back tests
  passed both while content was loading and after content appeared (2/2). The
  native macOS Debug app rebuilt/launched and the real LOTR chapter-boundary
  XCTest passed 1/1. Result bundle for the Mac boundary:
  `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.13_12-17-07--0300.xcresult`.

- [x] **APP-20261010-01 — Playback-near streaming and player UI parity.** Implemented, verified and merged.
  User-confirmed scope: on-demand `Listen` in the native iOS/macOS apps, then
  Flutter, generates only a small moving window of TTS chunks near the audible
  playback position, never more than one EPUB chapter ahead. A seek or chapter
  skip moves conversion priority; stale/farther work must stop before creating
  durable audio. Explicit `Download` and CLI conversion remain whole-book and
  non-streaming. Apple UI: the mini player has no progress bar; expanded-player
  book hero and Back/close control remain visible after center-tap interactions;
  reduce excess vertical gaps below controls and between stack elements. Show
  Play spinner only while the user-requested initial audio is pending; preserve
  Play/Pause while audio is already audible and later text/audio is loading.
  Verify the iPhone SE (1st generation) Simulator on iOS 15.5 and native macOS
  app, then Flutter parity. **Primary verification is the native iOS app on that
  exact Simulator; Mac and Flutter evidence is complementary.** Runtime preflight
  passed: iPhone SE (1st generation), iOS 15.5, UDID
  `C66CCB36-C43E-4174-861E-2FA713389C84`, and native `My Mac` target are available.
  Implementation now streams TTS chunks to playback, keeps the active chapter
  plus one ahead eligible, reprioritizes on navigation, discards stale in-flight
  chapter output, and avoids retaining a second complete chapter buffer.
  Swift/iOS and AppKit/macOS wire the moving playback window and chunk delivery.
  Flutter's embedded playback path now requests one Rust chapter at a time in
  the same current-plus-one window and drops results that became stale. Explicit
  Download and CLI still use whole-book conversion. Native UI changes remove
  mini-player progress, preserve expanded hero/close controls, tighten player
  spacing, and scope loading spinner to initial user-requested audio.
  Verification on the exact iOS Simulator: 3 focused XCTest and 2 UI tests
  passed in `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3-playback-final.xcresult`;
  installed/launched PID 19737 and inspected `/tmp/epubtomp3-ios15-primary.png`.
  Native macOS `mise run mac:run` rebuilt FFI/app and launched PID 19842; inspected
  `/tmp/epubtomp3-macos-primary.png` (mini-player has no progress bar). Flutter:
  22 focused streaming/player tests pass and `mise run flutter:analyze` reports
  no issues. `mise run flutter:build-apk-debug` succeeded; APK:
  `flutter_app/build/app/outputs/flutter-apk/app-debug.apk` (189 MB). No Android
  device/emulator is attached, so Flutter runtime interaction remains unverified;
  its chapter-window scheduler and Android channel request are covered by tests.
  Review found and fixed sparse chapter-index migration so empty EPUB chapters
  do not shift resumed playback; a regression test covers the old-job upgrade.
  Final diff audit and whitespace check passed; APK was rebuilt after final
  source adjustments. Commit `621a1439be` was pushed on
  `feature/playback-near-streaming`; PR #774 was merged into `master` on
  2026-10-10. Verified `origin/master` contains the commit. No CI/PR monitoring
  was performed. Android runtime remains the only verification limitation.

- [ ] **APP-20261010-01-ANDROID — Validate Flutter streaming on Android runtime.**
  Parent: APP-20261010-01. Status: pending; no Android runtime evidence recorded.
  Acceptance: an Android device or emulator is available; install and open the
  current debug APK at `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`;
  exercise playback and chapter advance; confirm conversion stays limited to the
  current chapter plus one ahead and obsolete work is discarded. Record device
  model, Android version, exact steps, observed result, and limitations. Leave
  pending until all criteria have real runtime evidence.

## Active requests — 2026-10-09

- [ ] **APP-20261009-47 — Keep playback clock ticks on progress controls.** Apple fix implemented; macOS playback interaction pending.
  At each 250 ms playback-clock tick, MiniPlayerBarHost, PlayerScreenController,
  and FullPlayerScreenController currently call their full render path; the full
  player also consumes a second position stream. Update only progress controls
  for clock ticks and keep structural state updates intact. Pietro prefers the
  oldest compatible technology for performance; support speed claims with a
  representative profile. Acceptance: regression coverage for progress updates,
  no repeated structural render work on clock ticks, and the real iOS 15.5
  iPhone SE (1st generation) Simulator plus native macOS app are exercised.
  Red/green: `PlayerPlaybackClockTests` initially found rebuilt rate menus;
  after the fix, 3 tests passed on iPhone SE (1st generation) Simulator / iOS
  15.5. Installed, launched, and inspected the LOTR reader with mini player and
  progress controls on that Simulator. Native AppKit target built with Xcode
  16.4 and the app launched, but no playback session was active to exercise a
  clock tick. Standard `mise run mac:run` is blocked in its unrelated Rust
  pre-build by `worker.rs` (`ChapterMetadata.source_index` and two missing TTS
  arguments); direct `xcodebuild` proved the native app target builds. No
  comparable Instruments profile was captured, so numeric speedup is unmeasured.
  Scoped source change keeps Combine/UIKit, limits clock subscribers to progress,
  and removes the full player's duplicate position stream. Commit/push on master.

- [x] **APP-20261009-46 — Standardize local app development and verification.**
  Completed in `AGENTS.md`, `CLAUDE.md`, `ios/EpubToMp3/AGENTS.md`, this board,
  and `handoff.md`: use this Mac and check required app targets before feature/bug
  work. Exact runtime requirements are in `docs/agent-workflow.md`. No app build
  or runtime check was needed for this
  instruction-only change.

## Active requests — 2026-10-09

- [x] **APP-20261009-48 — Stabilize agent tooling across macOS and the project.** Done; local tooling verification completed 2026-10-09.
  Update mise and keep its project Python shim fast; pin the current Codex CLI
  through the project mise manifest while preserving the global install; remove
  stale `.ai-jail` probe settings and warnings without weakening sandbox policy;
  upgrade ai-memory to the current native release with a verified pre-migration
  backup, preserve its local-only/no-LLM behavior, and validate the LaunchAgent,
  data migration, queue, and hook wiring. Record unsupported Intel/macOS sandbox
  limitations rather than claiming all warnings are fixable. Do not touch the
  user's unrelated local changes or monitor CI/PRs. Verification: mise 2026.10.6;
  `mise reshim` removed the missing-shim warning; Python 3.12.10 shim resolved,
  with three Starship Python module runs at 0.02 s each (initial timeout not
  reproduced). `mise doctor` still reports PATH shadowing by earlier Homebrew,
  Hermes and system executables; no global PATH rewrite was made. Codex global
  and mise-managed both report 0.162.0; both ran under ai-jail and returned the
  same version. Jail smoke test confirmed project-CWD persistence and denied
  writes to host home and `~/.hermes`; macOS still warns that `sandbox-exec` is a
  deprecated backend. ai-memory 2.6.2 is running in its LaunchAgent on
  127.0.0.1:49374; status reports 11 pages, 16 sessions, 26,714 observations,
  zero spool pending/retries, FTS complete, embeddings/LLM disabled, and OKF v0.2
  migration complete. SQLite integrity_check returned `ok`; MCP initialize
  returned HTTP 200; all seven Codex lifecycle hooks passed `--check-capture`.
  Upgrade and OKF migration backups remain available under
  `/Users/pips/ai-memory-backup-okf-v0.2-20261009-195550.tar.gz` and
  `~/.hermes/cache/scratch/ai-memory-pre-upgrade-20261009-162159.tar.gz`.
  No project-wide test suite, CI or PR monitoring was run.

## Active requests — 2026-10-08

- [ ] **APP-20261009-43 — Evict reader progress when removing a library entry.** Apple verified; Flutter parity pending.
  `LibraryStore.remove(id:)` deletes the book row but leaves its book-ID-keyed
  `ReaderProgressStore` entry. Evict through the store's actual persistence
  defaults (ReaderProgressStore uses `.standard`, which differs from the library
  App Group suite on device); retain other books' progress and the user's source EPUB. Add a native LibraryStore
  regression, then run the focused macOS XCTest. Do not change audio/model/download
  retention behavior in this slice. Apple fix: `LibraryStore.remove` now evicts
  a reader-progress entry from `.standard`, matching actual `ReaderProgressStore`
  writes rather than the LibraryStore App Group index. The initial same-suite
  test passed, but review caught that it did not model device defaults; corrected
  test failed red, then passed after the fix. Final
  `LibraryStoreTests/testImportThenRemoveRoundtrip`: 1 passed, 0 failed/skipped,
  including unrelated progress and source-EPUB preservation. Result:
  `Test-EpubToMp3Mac-2026.10.09_09-49-42--0300.xcresult`.
  Flutter parity is pending Arch; source handoff is in `handoff.md`.
  Review against `CODING_STANDARDS.md` caught and fixed the defaults-suite mismatch.
  Final diff changes only the library row/progress metadata and leaves audio,
  models, downloads, and source EPUB untouched. Apple acceptance is verified;
  keep APP-43 open until Arch verifies Flutter.

- [ ] **APP-20261009-41 — Reject partial or ambiguous Rust chapter selectors.** Arch-owned; source finding only.
  `converter-core/src/worker.rs` currently includes any chapter matching any
  requested selector, so valid + unknown selectors can silently convert only a
  subset; repeated/ambiguous selectors can collapse or match multiple chapters.
  Validate the complete selector set against parsed chapters before creating
  cache/output directories or invoking synthesis. Preserve `None` as full-book
  conversion; reject empty, unresolved, repeated and multiply-resolved selectors.
  Arch must add focused Rust tests at the production worker preflight seam:
  invalid requests yield no synthesis callbacks/artifacts/output directory, and
  valid positional ranges still produce exactly the requested chapters in source
  order. Rust verification belongs on Arch; no local Rust test was run here.

- [x] **APP-20261009-42 — Move embedded iOS conversion-history reads off MainActor.** Host verified; device launch pending.
  The conversions screen enumerated Rust job folders and decoded every local
  `manifest.json` inside a MainActor task. Move enumeration/read/decode to the
  shared utility worker, retain newest-first ordering and cancellation, and cap
  each manifest read at 1 MiB. Foundation XCTest: 2 new cases passed for actual
  worker-thread IO, ordering, and pre-cancelled no-IO; full task 22 passed, 0
  failures, 4 FFI-only skips. Generic `iphoneos` compile reached the Rust bundle
  phase without Swift errors, then stopped because the host has no iOS dylib
  signing identity. No Simulator, install, device UI, or library data changed.

- [x] **APP-20261009-40 — Verify staged import bytes against their content ID.** Verified on macOS.
  A source can change between identity hashing and copy. Check the staged copy
  before replacing the durable destination, and revalidate same-path imports.
  The injected-copy red test demonstrated that mismatched bytes were previously
  accepted. Final focused LibraryStore tests: 5 passed, 0 failed/skipped,
  including prior-byte/index preservation, self-import and successful replacement.
  Result: `.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_09-26-15--0300.xcresult`.

- [x] **APP-20261009-39 — Roll back imports rejected by the library index.** Verified on macOS.
  A failed async index commit must not leave an unindexed book published in
  memory. Roll back only import snapshots still unchanged at failure time, so a
  concurrent edit/removal is preserved; retain the durable source copy. Native
  red assertion reproduced the phantom in-memory book. Final focused macOS
  LibraryStore tests: 4 passed, 0 failed/skipped, including concurrent edit,
  reimport preservation and reload. Result:
  `.build/Logs/Test/Test-EpubToMp3Mac-2026.10.09_09-23-50--0300.xcresult`.

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
  Arch handoff: Flutter service source uses item-local skip position/duration;
  current skip tests exercise only the fake. Test actual segmented just_audio
  behavior and late endpoint resolution on Arch before claiming parity.

- [ ] **APP-20261009-38 — Reject repeated manual conversion submissions.** Apple verified; parity pending.
  UI guards run before scheduling asynchronous submit tasks. Enforce one active
  invocation at the actual ConvertViewModel boundary, preserving its options,
  result and playback isolation. Native suspended-executor regression required;
  no extra synthesis or artifact deletion.
  Native red executor count was two instead of one; final Mac class ten passed,
  iOS 16 new case one passed, all zero failures/skips. View-model entry guard
  preserves the active request and its result. No UI-tap or Flutter verification.
  Flutter ConvertScreen has a synchronous `_submitting` guard and disables its
  button while active; Arch handoff requests a held-completer duplicate-submit
  widget test to prove one starter call and preserved request/result.

- [ ] **APP-20261009-37 — Yield startup reader prewarm to foreground opens.** Apple behavior verified; budget/parity open.
  Startup prewarm currently has no retained cancellation handle and can decode
  two books while the user opens a reader. Cancel best-effort startup work before
  foreground reading without waiting on MainActor; check cancellation between
  books and before IO/decode/publication. Already-running synchronous decoding
  cannot be claimed interrupted. Native caller responsiveness/preservation tests
  and same-book before/after opening evidence required; 200 ms gate stays intact.
  Both Apple startup roots retain one managed utility task; reader load cancels
  it without awaiting. Mac: 13 cache tests plus one pre-cancel read passed.
  iOS 16: two helpers passed, caller initially failed stable-layout readiness;
  scene/layout-correct fixture then passed separately. Sources/bytes preserved.
  Matched relaunch measurements: LOTR 835.299 → 394.444 ms, Christie
  158.751 → 161.847 ms. Both runs fail LOTR's 200 ms gate; no causal speedup
  claim from one pair. Details and limits in the quality plan; Flutter unverified.

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
  real-book navigation latency remain unverified. Arch handoff requests a
  retained seek through late segment/final-duration confirmation. Evidence in
  the quality plan and `handoff.md`.

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
  iOS projection-first implementation now validates the persisted active chapter
  against the source-bound complete catalog before rendering, commits saved
  position against final UIKit geometry, and keeps navigation disabled until the
  full payload attaches. Added injectable catalog/store seams and a UIKit test
  that suspends catalog hydration; red reproduced blank content and wrong chapter,
  then green passed with chapter 6 visible, readableContent recorded, and 0.6
  position restored, and mismatched hydrated title exercised fallback (iPhone SE
  1st gen/iOS 15.5, `14-46-22`). Projection writes are queued off-main after
  chapter presentation/progress. Actual seeded LOTR pagination/chrome passed 1/1
  on exact iPhone SE 1st gen/iOS 15.5 (`14-48-03`), no clipped lines; app left
  open at Contents 1/5. `mise run mac:run` built/launched the native Debug app
  (PID 27393). iOS process-relaunch timing, repeated 200 ms two-host gate, and
  broader supported-geometry sweep remain open.

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

- [ ] **APP-20261009-23 — Validate both actual books on the physical iPhone.** In progress; device unavailable.
  Validate The Lord of the Rings and E não sobrou nenhum using native automation
  on the physical iPhone. The active quality goal prohibits Simulator, so do not
  repeat the historical iOS 16 SE runs. Latest `xcrun devicectl list devices`
  reports paired iPhone 16e `44B2CFBD-2193-5086-8E8D-BF7A2876C321` unavailable.
  Resume device verification only when it becomes available. Keep conversion
  limited to LOTR 8–9 and Christie 6–7, zero-based inclusive.
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
  Historical authorized Simulator run on 2026-10-09 opened the installed app in
  the iOS 16 SE Simulator.
  Focused real-book UI tests opened both EPUBs (3 pages each) and reported zero
  clipped lines, but both failed to advance from page 1 after the horizontal
  drag. LOTR probe diagnostic `swipeActions=0` confirms neither directional
  callback ran; gesture delivery, not pagination geometry, is the unresolved
  seam. Six focused UI executions (nine real-book cases) reproduced failures;
  the combined run passed two unit tests but failed both real-book UI tests.
  Latest diagnostic: `.build/Logs/Test/Test-EpubToMp3-2026.10.09_10-07-07--0300.xcresult`
  (one LOTR UI test failed, `swipeActions=0`). No attempted gesture change was
  retained and no TTS was rerun. This evidence does not replace the required
  physical-device validation under the active goal constraints.
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

- [ ] **APP-20261009-21 — Active-chapter relaunch critical path.** Partial optimization measured; 200 ms target pending.
  Two-host actual-window profiling confirms prepared attributed archive hits;
  LOTR full-book read/decode ~130 ms, restore ~5 ms, presentation ~5 ms, initial
  window/attach/layout cumulative ~93 ms. State/table setup ~23 ms includes restore.
  Preserve 200 ms gate and source/style integrity; avoid decoding the whole book
  before restoring the active chapter. Detailed evidence in
  `docs/plans/2026-10-09-reader-opening-profile.md`. No source fix claimed; temporary
  tagged probes removed, original cache/book bytes preserved. Additional same-range
  two-host repeat `reader-relaunch-86F998D4-805C-4493-A999-99819BB90ED9`: prepare
  passed, verify failed; LOTR 355.265 ms end-to-end / 261.333 ms readable, Christie
  145.430 / 125.247 ms. No synthesis, baseline executable unavailable, so no causal
  speedup claim. Resident/physical memory values are point samples, not peaks.
  Next measured experiment: persist the source identity and SHA binding in the
  prepared chapter snapshot, then use descriptor metadata on unchanged relaunches;
  any identity mismatch must retain full SHA validation. Acceptance requires
  source replacement/mutation regressions and a paired actual-book timing run.
  Implemented as a measured partial slice: identity+SHA now survive serialization;
  unchanged source reads take the descriptor metadata path, while legacy/mismatched
  identity falls back to the full SHA and refreshes the snapshot. Eight store tests
  and five macOS active-chapter tests passed. Actual LOTR/Christie two-host run
  (`reader-identity-8F946CA8-5542-4C90-A94B-E9A6AD093D08`) prepared successfully;
  verify failed the 200 ms gate for LOTR at 214.308 ms. Its source projection read
  took 3.104 ms; `reader_load_task_scheduled` to `reader_load_task_started` took
  96.365 ms. Christie was 96.083 ms. The optimization reduced source validation
  work but does not complete the end-to-end target; repeat verify was invalid after
  fixture cleanup and is not counted as a measurement.
  Current-source iOS reader UI check also passed on iPhone SE (1st generation),
  iOS 15.5: one LOTR pagination/chrome test, zero failures/skips
  (`reader-identity-ios15-5-lotr.xcresult`); app left open at Contents 1/5.
  Next diagnostic records `viewDidLoad/configureReader` and AppKit appearance/layout
  callback boundaries to locate the measured gap after task scheduling. The host
  sample taken later was load average 2.09/2.63/2.86 and is not a contemporaneous
  control for the prior 214.308 ms result.
  A Release optimized app/test profile (with local signing disabled and test hooks
  enabled) still failed LOTR at 214.554 ms; Christie was 89.880 ms. For LOTR the
  task started 76.396 ms after the initial layout, after a 95.518 ms schedule/start
  gap. Release mode alone does not remove the delay. Next isolate XCTest's
  main-actor readiness polling from AppKit actor scheduling.
  Lifecycle profile confirmed both a main-queue ping and a MainActor ping waited
  until the XCTest `Task.sleep(10 ms)` resumed (about 70 ms later); neither the
  task nor pings ran during the wait. Replace the sleep poll with XCTest's
  run-loop-aware expectation wait before drawing conclusions about app scheduling.
  The expectation wait itself resumed 1.104 s after startup while the attached
  `controls_usable` stage was 185.718 ms. The reported point was therefore timing
  XCTest resumption, not readiness. Make the benchmark point derive from the
  readiness stage whenever the stage recorder is present. **Superseded by the
  corrected measurement below:** the report now takes the actual `controls_usable`
  timestamp and macOS XCTest waits on that callback. A regression assertion binds
  the reported point to readiness and preserves the 200 ms gate. Two separate
  Release prepare/verify host pairs passed with LOTR 186.676 and 178.608 ms and
  Christie 61.720 and 62.534 ms, zero test failures/skips. Evidence:
  `.reports/mobile-audio/reader-direct-readiness-release-36BE15E5-22B0-49FA-990E-23DA90DCC388/`
  and `.reports/mobile-audio/reader-direct-readiness-repeat-1DB107C0-99B2-4851-9D1C-B119873AD321/`.
  Current-source UI regression passed on exact iPhone SE 1st generation/iOS 15.5
  using Xcode 16.4 (1/1); `mise run mac:run` built/launched the native Mac app and
  LOTR opened at Chapter 12. Mac geometry gate and iOS process-relaunch latency
  parity remain unverified; APP21 remains open.
  iOS projection-first implementation now source-validates the active chapter and
  full catalog before rendering, commits saved position against final UIKit
  geometry, and blocks navigation until payload hydration. The red regression
  previously observed blank content/wrong chapter; two native iOS 15.5 Simulator
  tests now pass, including saved offset 0.6 and mismatched-title fallback
  (`14-46-22`). Actual seeded LOTR pagination/chrome passed 1/1 (`14-48-03`),
  no clipped lines; app left open at Contents 1/5. `mise run mac:run` built and
  launched Debug Mac app (PID 27393). iOS process-relaunch timing, repeated
  200 ms two-host gate, and broader supported-geometry sweep remain open.
  Reentrant same-book opening is now guarded and covered by a red/green
  follow-up. Secure renderer archive decoding now runs in its worker actor;
  the root startup restore enables gestures without waiting an extra main-queue
  turn, while library-tap openings keep their deferral. Interaction-mode state
  is reapplied even when viewport geometry is unchanged. On iPhone SE 1st gen/
  iOS 15.5, focused native tests passed 10/10 (`18-17-49`) and seeded LOTR
  pagination/chrome passed 1/1 (`18-18-42`). macOS renderer/active-chapter tests
  passed 11/11 (`Test-EpubToMp3Mac-2026.10.11_18-15-48--0300.xcresult`); the
  Debug app opened LOTR Chapter 12. Actual iOS launch samples remain variable:
  one three-run set was 214.7/247.4, 212.0/236.8, 203.3/227.7 ms (readable/
  controls); after the UI run, six warm repeats ranged 287–617/359–656 ms.
  All actual app readings miss 200 ms; controller/UI correctness passes do not
  satisfy production relaunch latency. Next profile root-to-reader MainActor
  availability and TextKit commit timing under the same exact simulator.
  `MainReaderScreenController` regression. Exact iOS 15.5 Simulator XCTest passes
  3/3 (active chapter plus same-book reentrancy). Three warm LOTR app relaunches
  after this fix each used the source-validated disk projection and prepared
  renderer, but readiness measured 390–448 ms from `reader_open_requested`;
  `reader_load_task_started` lagged scheduling by 209–220 ms. The 200 ms gate
  remains red. Next isolate/optimize the main-actor/layout scheduling gap and
  repeat actual relaunch timing; temporary `[DEBUG-app21-profile]` logging must
  be removed before delivery.
  Follow-up profile found that earlier relaunches incorrectly included the
  explicit `-developmentSeedBook` import path, which hashes LOTR synchronously;
  clean relaunches omit it and retain the existing library item. The same 214–269
  ms schedule/start gap remains without seeding. Root lifecycle markers locate
  ~78 ms in the initial Now Playing cover-art sync during mini-player refresh;
  Time Profiler all-process runs materially perturbed startup and are not treated
  as latency evidence. A first attempt to defer that Now Playing side effect was
  followed by two LOTR UI runs that reported the same stale page-probe mismatch;
  the deferred callback was removed. The current narrower policy suppresses
  Now Playing cover publication when there is no audio snapshot, conversion or
  queue, while the in-app mini player still reads its cover directly from the
  library. Its focused policy test and a post-change real-book UI run are pending.
  Three instrumented relaunches before that adjustment reported controls at
  345.5, 351.7 and 446.0 ms; all fail the unchanged 200 ms gate and do not prove
  a causal speedup. Temporary root/task logging and scheduler pings are removed.
  Follow-up diagnosis found the repeated chrome failure was in the UI harness:
  once chrome was hidden, its page indicator was no longer hittable, but the
  harness kept filtering the new viewport probe against the cached visible-mode
  total (5 pages vs 4). The harness now trusts the indicator only while visible
  and waits for a probe tagged with the expected chrome state. On the exact
  iPhone SE (1st generation)/iOS 15.5 Simulator, the real LOTR pagination/chrome
  test passed with no clipped lines (`Test-EpubToMp3-2026.10.11_16-03-22`,
  Xcode reported TEST SUCCEEDED; its attachment database emitted an unrelated
  `mkstemp` save warning). Focused iOS native tests passed 6/6; two opt-in
  benchmark tests were skipped because their explicit input manifest was absent.
  Christie’s real-book UI case could not start because that EPUB is not seeded
  into the Simulator library; this is a fixture availability limit, not a layout
  result. The actual two-host iOS relaunch gate was then run with the registered
  LOTR 8–9 / Christie 6–7 inputs and full SHA validation, in separate XCTest
  hosts on the same exact Simulator. Two independent prepare/verify pairs passed:
  LOTR 157.765 and 151.505 ms; Christie 160.128 and 160.833 ms. Each point is
  measured through `controls_usable`; the 200 ms threshold and source integrity
  checks were unchanged. Raw two-host `.xcresult` bundles and the input manifest
  are preserved under `.reports/mobile-audio/reader-relaunch-ios15-20261011/`.
  The temporary scheme/test-plan environment forwarding was removed after
  measurement. `mise run mac:run` built and launched Debug with
  Xcode 26.3; Xcode 16.4 against the 26.3 DerivedData had a stale-toolchain
  link error and is not counted. Final real-reader interaction in the Mac app,
  leave-open verification on iOS, and final diff review remain pending.
  Follow-up: on the exact iPhone SE (1st generation)/iOS 15.5, the final focused
  Simulator run passed 11 tests, zero failures/skips, including reader
  presentation state, recent-cache prewarm exclusion, thumbnail decode, and the
  real seeded LOTR swipe/chrome/clipping UI test. Geometry profiling showed the
  reader now reserves the final mini-player height while loading, so the first
  content pagination uses the final 320x400 viewport; the mini-player remains
  visually hidden until content is ready. The root also excludes the active
  reader/player books from background prewarming and skips a duplicate fulltext
  title decode for the active reader. The mini-player cover now uses the existing
  bounded thumbnail cache and background decoder instead of full-resolution
  synchronous UIImage decoding. These changes have correctness evidence but no
  demonstrated latency reduction yet: two uninstrumented real-app relaunches on
  the same persisted LOTR chapter measured readable content at 515.964 and
  513.673 ms, controls at 590.184 and 590.574 ms. Both fail the unchanged 200 ms
  requirement. Journey IDs `5645F70A-A579-4C76-8385-F411162D3429` and
  `87DCEB37-3C01-4888-A225-22C7F9EA8B8B`. The app is left open on LOTR Foreword,
  page 1/11; screenshot `/tmp/app21-final-open.png`. Do not close APP21; actual
  app performance and the complete Mac geometry gate remain outstanding.
  Latest next-step diagnosis exported both successful iOS 15.5 relaunch reports:
  LOTR 157.765 and 151.505 ms, Christie 160.128 and 160.833 ms. On the LOTR
  critical path, `reader_load_task_scheduled`→`reader_load_task_started` was
  120.4 and 114.4 ms; the projection snapshot load+validation took under 0.5 ms,
  renderer lookup/reuse ~20–22 ms, and final readiness was ~151–158 ms. Initial
  reader view load completed by ~10 ms and initial layout by ~15–21 ms. This
  narrows the gate's dominant interval to MainActor task scheduling after reader
  setup. The separate uninstrumented Foreword app journeys remain ~590 ms and
  are not interchangeable with the chapter 8–9 process-relaunch gate. Next:
  start the validated projection read independently of the reader's MainActor
  task, then deliver its result to presentation; first add cancellation, book
  generation, saved-position and source/style validation regressions. No code
  change or latency improvement is claimed from this diagnosis.
  Follow-up implemented that read/validation on a detached task, carrying the
  captured progress entry with the source-validated, complete-catalog snapshot.
  Validation now precedes MainActor task start by 120–450 ms in the sampled
  iOS 15.5 runs, and the saved 0.6 position plus mismatched-catalog fallback
  tests pass (2/2). This did not close the budget: two-host LOTR/Christie
  verification runs measured 175.907/798.957 ms, 523.937/228.822 ms and
  597.082/241.340 ms. High-priority scheduling did not produce repeatable
  improvement and was reverted. Added optional renderer restore start/end stages;
  the latest sample spent 55.5 ms inside renderer restore for LOTR and 24.4 ms
  for Christie, while MainActor task start lagged 520/126 ms. The 200 ms gate is
  still red; continue diagnosing MainActor availability and the ~81 ms Christie
  final layout interval. Evidence: `.reports/mobile-audio/app21-ios15-projection-worker-final/`,
  `...-priority/`, and `...-renderer-restore-profile/`. The iOS activation probe
  recorded `UIApplication.applicationState` and key-window status. One two-host
  sample measured 109.153 ms LOTR / 132.639 ms Christie, but both synthetic reader
  windows were not key; this sample is diagnostic only and does not pass APP21.
  Next attach the measured reader to the active UIWindowScene and require its
  window to be key before counting timings. Evidence:
  `.reports/mobile-audio/app21-ios15-activation-probe/`.
  **Follow-up:** the harness now uses the active scene and asserts a key reader
  window. However, it still forced that window to 390x844 pt; the exact iPhone SE
  scene is 320x568 pt. Thus the following two passes are diagnostic only, not
  valid device-geometry acceptance: LOTR
  121.542/123.491 ms, Christie 140.816/139.551 ms; both readers became visible
  in a key window. Reports: `.reports/mobile-audio/app21-ios15-key-window-gate/`
  and `...-repeat/`. These controller-level gates exclude production root startup.
  A clean app-process relaunch with persisted LOTR still measured 325.127 ms to
  readable content and 374.767 ms to controls (`6DF7D668-1BDF-4216-BE08-D2AB3C08E3E0`),
  so APP21 remains open. The real app is left open on LOTR page 1/11. Next profile
  root startup and its handoff to `MainReaderScreenController`; preserve this
  actual-app measurement as the acceptance authority. The clean relaunch stage
  profile (`/tmp/app21-current-stages.log`) measured task start at 195.467 ms,
  renderer restore at 23.074 ms, first paginated layout at 42.582 ms, and another
  layout before readable content at 40.487 ms. Re-run on actual device geometry;
  do not use the prior enlarged-window passes as evidence. Source inspection
  found that `showChapter` and `hideLoadingOverlay` apply the same reader layout
  mode; each call resets `lastPaginatedViewportSize`, forcing another full TextKit
  layout. Make this application idempotent and add an active-chapter regression
  that verifies readiness does not trigger duplicate pagination while preserving
  saved offset and waiting for controls to become interactive. Root-stage profile
  shows eager full-player embedding costs about 25 ms while the actual app is
  restoring the reader, and root `viewDidLoad` takes about 90 ms. Defer creation
  of the full-player controller until expansion; preserve the existing compact
  full-player UI regression as the acceptance check.
  Follow-up on the exact iOS 15.5 Simulator: compact full-player UI test now
  passes after protecting mini-player hide-animation completion with a generation
  check; test dismisses the player to leave persisted presentation state clean.
  Real LOTR warm relaunch still misses 200 ms (316/382 ms). Profile showed the
  prepared projection absent; the app-container archive had an older source
  inode than the subsequently atomically replaced fulltext file. Next serialize
  fulltext save before projection snapshot creation, then verify an actual app
  relaunch reads the validated projection and measure the same readiness clock.
  Save/projection are now one ordered background operation, and a regression
  replaces the fulltext atomically before requiring the reopened snapshot to
  match. On iPhone SE/iOS 15.5, LocalFulltextCache + active-chapter + compact
  full-player UI checks passed 4/4 after the final logger removal. Instrumented
  app profiling confirmed a validated projection and renderer cache hit; it
  located `reader_load_task_started` at 228 ms, projection validation at 23 ms,
  and renderer restore at ~37 ms. Two uninstrumented LOTR warm app relaunches
  measured 223.445/276.772 ms and 231.120/287.074 ms (readable/controls), so both
  miss the unchanged 200 ms gate. The temporary profiling logger is removed.
  `mise run mac:run` built and launched the native Mac app; the real LOTR reader
  was exercised at Chapter 12. The remaining measured iOS bottleneck is startup
  and task handoff before the prepared reader restoration begins. A three-launch
  baseline with startup recent-book prewarming enabled measured 251.727/320.248,
  245.560/310.462, and 228.602/288.150 ms (readable/controls). Next compare an
  otherwise identical build with that concurrent startup prewarm disabled; retain
  the feature only if it does not contend with the foreground reader. The disabled
  variant measured 283.753/353.800, 254.891/313.193, and 262.861/323.563 ms; its
  median was slower by 17.3/13.1 ms. This sequential comparison does not prove
  causation, so restore the current active-book exclusion policy and move the
  investigation to actual root/controller stage profiling. A detached restore
  task passed the two active-chapter tests but gave no clear real-app benefit:
  246.245/302.621, 237.420/299.249, and 261.983/328.969 ms (median
  246.245/302.621 versus 245.560/310.462 ms before). Reverted that experiment;
  the source-bound projection remains read off-main and UI restoration stays on
  MainActor. A temporary real-app stage profile then placed projection validation
  at +9 ms, root viewDidLoad from +25 to +108 ms, scheduled load task at +2 ms but
  task start at +190 ms, renderer restore +192 to +251 ms, readable content +293 ms,
  and controls +371 ms. The logger caused repeated render entries and materially
  perturbed latency, so these values locate ordering only, not acceptance. The next
  measured slice moves only source- and style-validated archive decode into a worker
  while preserving MainActor TextKit presentation, then repeats the uninstrumented
  actual-app relaunch. No 200 ms pass is claimed.
  Follow-up: renderer restoration was delivered from a validated worker slot on the
  first committed UIKit layout; saved-position restoration now waits for a nonzero
  scrollable content extent. Focused active-chapter tests passed 3/3, main-reader
  tests 3/3, and root-presentation tests 6/6. The seeded real LOTR pagination/chrome
  UI test passed 1/1 on iPhone SE (1st generation), iOS 15.5, including saved-offset
  round trips; the test result bundle emitted an unrelated attachment `mkstemp`
  warning while XCTest still reported TEST EXECUTE SUCCEEDED. The open app screenshot
  shows Foreword page 1/11 without clipped text. A clean actual-app launch with
  `-app21TimingProfile` measured `readable_content` at 277.8 ms and `controls_usable`
  at 346.7 ms, both above 200 ms. It located layout commit at 208.4 ms and reader
  load-task start at 249.5 ms; this instrumented run is diagnostic, not an
  uninstrumented acceptance sample. The Mac app built and opened the seeded LOTR at
  Chapter 12 with visible text and controls using Xcode 26.3; `mise run mac:run` with
  Xcode 16.4 first failed at link. APP21 remains open; next isolate root overlay
  refreshes and the MainActor scheduling interval, then rerun uninstrumented paired
  actual-app timings and the Mac geometry sequence.
  Latest diagnosis found that the content-ready callback requested a chrome
  transition to the already-visible state, forcing a redundant viewport commit.
  The coordinator now ignores repeated same-state requests. A reader-only layout
  pass also commits the measured content height before restoring the saved offset.
  The focused native suites passed 13/13 after the idempotence change and 10/10
  after the final layout adjustment; the seeded LOTR pagination/chrome UI test then
  passed 1/1 with zero failures. Three clean, uninstrumented app-process relaunches
  on the exact iPhone SE/iOS 15.5 persisted `prepared_disk` journeys with readable/
  controls times of 188.820/192.236, 181.533/183.900, and 184.454/186.765 ms. The
  app remains open on LOTR Foreword page 1/11 (`/tmp/app21-current-reader-final.png`).
  The Mac Debug app opened LOTR Chapter 12; a real right-arrow page turn scrolled
  the text with no visible clipping. APP21 still needs the full native Mac geometry
  sequence and final source/diff review before closure.
  Final first-layout follow-up: the root now ignores a chrome request when its
  target already matches the committed state, avoiding a redundant root geometry
  transaction. `BookOpenScreenController` lays out the scroll surface after the
  measured TextKit height is applied, then restores the saved position against that
  same committed extent. On exact iPhone SE/iOS 15.5, focused controller/root tests
  passed 10/10 (`Test-EpubToMp3-2026.10.11_19-01-46--0300.xcresult`), the real LOTR
  pagination/chrome test passed 1/1 (`...19-02-48...`), and the additional native
  matrix passed 4/4 (`Test-EpubToMp3-2026.10.11_19-05-05--0300.xcresult`): eight
  actual-LOTR chrome round trips without offset drift, landscape glyph checks,
  small serif rapid toggles, and continuous-scroll chrome/drag behavior. A profiled
  process launch recorded readable/controls at 187.105/189.040 ms; the separate
  uninstrumented persisted journeys below are the acceptance measurements. Three
  clean app-process relaunches loaded `prepared_disk` and measured 188.820/192.236,
  181.533/183.900, and 184.454/186.765 ms (readable/controls), all under 200 ms.
  `mise run mac:run` rebuilt with Xcode 26.3 and opened LOTR Chapter 12; the Mac
  right-arrow page turn scrolled text without visible clipping (`/tmp/app21-mac-page-turn-final.png`).
  The Simulator app is left open on LOTR Contents page 1/6 without visible clipping
  (`/tmp/app21-current-reader-final.png`); the seeding helper reported its source
  EPUB unavailable, but the previously imported real LOTR remained in the library.
  Mac geometry follow-up: exercised the running native app with real LOTR in
  Paginated and Scrolling modes, moved forward/back, changed to the smaller serif
  size, and resized the window between 1250x850 and the 1000x700 minimum. No glyph
  clipping was visible in the captured app states. Focused macOS tests ran 10 total:
  `MacReaderTextLayoutTests` 2/2 and `MacReaderOpeningReadinessTests` 6/6 passed;
  `MacReaderChapterNavigationTests` had one pass and one deterministic failure in
  `testBackwardChapterCrossingAfterOpeningTableOfContents()`. Its assertion gets
  a scroll offset of 5163 pt versus a frame-derived expected end of 5167 pt; eight
  later assertions cascade from that mismatch. An isolated rerun failed the same
  way. This does not establish visible glyph clipping, but leaves the Mac chapter
  boundary geometry gate unresolved. Simulator was relaunched without reseeding;
  PID 68013 is active on exact iPhone SE/iOS 15.5 and LOTR Contents 1/6 is visible
  (`/tmp/app21-ios-resumed.png`). Follow-up on 2026-10-12 updated chapter-end
  detection to compare the visible document rect with the last laid-out glyph and
  changed the focused test to assert glyph containment, legal scroll extent, and
  persisted chapter progress instead of frame-height equality. Focused Mac XCTest:
  `xcodebuild test -project EpubToMp3.xcodeproj -scheme EpubToMp3Mac
  -destination 'platform=macOS' -derivedDataPath ./.build
  -only-testing:EpubToMp3Tests/MacReaderChapterNavigationTests` passed 2/2, zero
  failures/skips (`Test-EpubToMp3Mac-2026.10.12_14-11-01--0300.xcresult`). The
  current Debug Mac app was launched (PID 7859), but the actual-LOTR Mac chapter
  boundary has not yet been covered by automated UI interaction. A second focused Mac run including chapter navigation,
  opening readiness and text layout passed 10/10 (zero failures/skips) in
  `Test-EpubToMp3Mac-2026.10.12_14-34-44--0300.xcresult`. Exact iPhone SE/iOS
  15.5 app opened with the existing LOTR library and showed Contents 1/6
  (`/tmp/auto-prompt-execute-ios15-final.png`). The UI regression could not run:
  the task's `vendor:python` dependency is undefined locally, and direct
  `xcodebuild test-without-building` rejected the iOS 15.5 destination before
  starting tests because the active Xcode 26.3 does not list that legacy runtime.
  Added the missing `vendor:python` mise task, which installs/verifies the pinned
  project Python 3.12.10 (already present locally). Under Xcode 16.4, the actual
  LOTR pagination/chrome UI regression passed 1/1 on iPhone SE (1st generation),
  iOS 15.5, with zero failures/skips (`Test-EpubToMp3-2026.10.12_14-37-40--0300.xcresult`);
  app was relaunched and left open on LOTR Note on the 50th Anniversary Edition,
  page 1/14 (`/tmp/app21-ios15-xcode16-final.png`). Mac focused XCTest 10/10 had
  passed under Xcode 26.3 earlier this run. A repeat under Xcode 16.4 failed at
  link (`_swift_coroFrameAlloc`, unavailable newer frameworks) after reusing the
  shared `.build` cache; no Mac tests ran in that attempt. A new AppKit regression
  uses the locally imported LOTR chapter text in an isolated in-memory payload,
  navigates backward from the current chapter's start into the long previous chapter,
  asserts final glyph containment and bounded trailing space, then navigates
  forward and checks progress. It restores reader progress/defaults, drops only
  the process-warm copy during setup, and leaves the durable fulltext untouched.
  Under Xcode 16.4 in isolated `.build-app21-xcode16`, chapter navigation,
  opening readiness, and text layout passed 11/11 (zero failures/skips), result
  `Test-EpubToMp3Mac-2026.10.12_15-06-58--0300.xcresult`. Mac app PID 12855 was
  relaunched from that build; screenshot `/tmp/app21-mac-xcode16-final.png` shows
  the LOTR library card. On the exact iPhone SE (1st generation)/iOS 15.5, the
  official Simulator task repeated `testActualLOTRReaderPaginationAndChrome`
  against the final sources and passed 1/1 in 21.848 s, zero failures/skips,
  `TEST EXECUTE SUCCEEDED`, result
  `Test-EpubToMp3-2026.10.12_15-08-31--0300.xcresult`; app was relaunched and
  left open on LOTR Prologue, page 1/39 (`/tmp/app21-ios15-xcode16-final3.png`).
  This closes the
  real-book geometry verification gap. APP21 remains open because its separate
  real-app 200 ms warm-relaunch acceptance has not been remeasured by this slice.
  The agent owns all verification; no user-run testing is required.

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
  Latest pre-optimization two-host run: LOTR 504.574 ms end-to-end and 342.986 ms
  readable-content milestone; Christie 156.508 ms. The full 200 ms gate is still red.
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
  Projection validation now performs one full-source SHA-256 pass instead of two.
  It compares scanned source identity (device, inode, size, nanosecond mtime/ctime)
  after archive delivery and after decoding; envelope signature and archive checksum
  remain checked. Final native macOS store/window tests passed 10/10, zero skips
  (`Test-EpubToMp3Mac-2026.10.11_11-21-40--0300.xcresult`), including changed and
  identical-byte atomic replacement during archive read. Exact iPhone SE 1st
  generation/iOS 15.5 store tests passed 8/8, zero skips
  (`.reports/simulator-smoke-store-final-252FE39A-736B-40A3-AF46-6B1C9560E104/tests.xcresult`).
  Same-hash isolated macOS Debug projection medians: LOTR 188.377→88.680 ms,
  Christie 15.822→7.403 ms across separate three-sample runs; diagnostic only, not
  paired statistical evidence or reader-open latency
  (`.reports/mobile-audio/reader-relaunch-5FB959AD-4D2D-4EFA-B65E-356596E324DA/projection.xcresult`).
  Full 200 ms opening gate
  and complete two-app visual-reader probe remain open.
  Final actual LOTR/Christie process-relaunch run: prepare passed; verify failed
  the unchanged threshold in `.reports/mobile-audio/reader-relaunch-AAE0936D-61FF-4986-A0F0-33495BE19D38/verify.xcresult`.
  LOTR 361.070 ms end-to-end, readable 223.629 ms, controls 264.570 ms; Christie
  151.107 ms. Before/after runs are unpaired, so causality is unproven.
  The seeded-LOTR UI test could not find its book in the test runner's fresh app
  container. A hash-verified LOTR was manually staged/imported in the exact SE/iOS
  15.5 app; paginated contents opened and was left visible in
  `.reports/reader-ios15-5-lotr-final.png`. The full clipping/chrome/page-turn probe
  remains unverified. Latest run-stage instrumentation records first arrival, full
  catalog and projection read, restore, presentation and window setup. A scheduling
  candidate starts both prepared reads before window attachment; two unpaired LOTR
  runs measured 230.064 and 239.957 ms end-to-end, 117.588/133.512 ms readable and
  159.186/171.221 ms controls from the reader request. Both still fail the unchanged
  200 ms end-to-end gate. A no-projection experiment measured 236.569 ms, so it did
  not show a meaningful benefit. Source-mapped catalog read/decode median was 114.1
  vs 119.5 ms ordinary on LOTR and 12.6 vs 12.4 ms on Christie; no production
  change. Relevant Mac reader tests passed 13/13, zero skips in
  `Test-EpubToMp3Mac-2026.10.11_11-40-00--0300.xcresult`. Exact iPhone SE 1st
  generation/iOS 15.5 app was installed/launched and displayed LOTR contents at
  `.reports/reader-ios15-5-current.png`; native Mac app launched and displayed LOTR
  chapter 12 at `.reports/reader-macos-loaded.png`. Complete clipping/chrome/page-turn
  gate and 200 ms acceptance remain open. Latest reports:
  `.reports/mobile-audio/reader-relaunch-66CFCBBD-044E-4710-9132-AAD0B60E7CC9`,
  `reader-relaunch-F79FFDB1-20F5-4B33-8914-3359368CFB9A`,
  `reader-relaunch-BD825F5D-CDD9-45D3-846E-10CE0555608A`, and
  `reader-relaunch-92A8BF36-B8D8-465E-AA5E-0DDFFB11FAE0`.
  Catalog-shape experiment decodes only job/title/author, chapter index/name, and
  TOC while preserving complete source-file bytes. One native test passed, zero
  failures/skips in `.reports/mobile-audio/reader-relaunch-ED45D223-9C6C-4FEE-9810-F1DE88D57284/projection.xcresult`:
  LOTR full-file read+decode median 110.106 ms, full-file read+index decode
  13.469 ms, and a separate 5,249-byte encoded index read+decode 0.747 ms; Christie
  12.173/1.892/0.824 ms. This diagnostic shows a cheap metadata decode but does not
  establish full reader correctness or a 200 ms pass. Implemented follow-up: the
  source-hash-bound prepared snapshot now carries all chapter metadata; Mac renders
  the restored active chapter, commits saved position, rechecks source file identity,
  then enables controls before starting the full catalog decode. TOC chapter
  navigation remains gated until hydration; mismatched catalog data replaces the
  projection. Focused macOS tests passed 21/21, zero skips, in
  `Test-EpubToMp3Mac-2026.10.11_12-18-03--0300.xcresult`. Actual same-hash LOTR/
  Christie two-host relaunch test passed three successive candidate executions,
  unchanged 200 ms assertion: LOTR outer 191.552, 195.079 and 194.885 ms. Latest
  ready controls at ~184.947 ms; full catalog starts ~185.044 ms. These are unpaired
  samples with only ~5 ms outer margin; do not claim stable latency improvement or
  close APP-20261008-07. Diagnostic/evidence in
  `.reports/mobile-audio/reader-relaunch-FD71E526-B227-4399-8C61-533E2AD44F0C`.
  macOS Debug build succeeded. Current Debug Simulator artifact was reinstalled on
  the exact booted iPhone SE (1st generation)/iOS 15.5; the SHA-verified seeded LOTR
  opened to Contents, page 1/5, and app remains open in
  `.reports/reader-ios15-5-current.png`. This is a prior artifact (11:19): the
  current Xcode scheme has no eligible Simulator destination (`mise run ios:build`
  stopped at its destination guard because iOS 26.2 platform is unavailable).
  Follow-up supersedes the prior iOS status: Xcode 16.4 built the current source,
  and the exact iPhone SE 1st generation/iOS 15.5 real-LOTR UI test passed 1/1,
  zero failures/skips. It verified visible swipe forward/back, two chrome
  hide/show offset-and-anchor round trips, and zero clipping. The app was relaunched
  with the seeded LOTR and left open at Contents 1/5 in
  `.reports/reader-ios15-5-current.png`. Mac app remains built/launched; the full
  Mac geometry sequence remains unverified. APP-20261008-07 and APP-20261009-21
  remain open.
  Follow-up on the exact iPhone SE (1st generation)/iOS 15.5, current real app
  binary: terminated and relaunched twice with LOTR already persisted, without
  test launch arguments. Persistent app telemetry recorded prepared-disk opens:
  latest prior sample readable 289.380 ms / controls 335.980 ms; fresh relaunch
  readable 280.652 ms / controls 331.630 ms. Both miss the unchanged 200 ms
  real-app gate. The projection-first two-host XCTest passes (151.5–160.8 ms)
  are controller-host timing with injected delayed catalog hydration and do not
  override this app-process result. The iOS app is left open on LOTR Contents 1/5;
  visible screenshot `/tmp/app21-resume-relaunch.png`. Exact UI geometry test passed
  1/1 earlier; macOS focused reader tests passed 13/13 and the Mac app displayed
  LOTR chapter 12, but full Mac geometry sequence remains unverified. Keep
  APP-20261008-07 and APP-20261009-21 open. Actual-app telemetry is in the app
  container's `Diagnostics/latency-observations.json` (journey IDs
  `157EE47E-A11A-4CA8-AF8A-DAAA2086A0F4` and
  `B0117B82-4980-44BE-8C38-AEDAA7CAB2A2`).
  Same-executable two-host repeat under host memory pressure produced an outlier:
  LOTR 455.571 ms (window visible 216.499, reader task started 405.632, controls
  usable 446.633); Christie 110.491 ms. With no source/binary change, a second
  pair passed the unchanged threshold: LOTR 197.302 ms (window 93.353, reader task
  161.066, controls 187.325); Christie 72.167 ms. The host had ~1.88M pages
  compressed and ~4.57M swapouts. These unpaired samples show high variance; they
  do not close the 200 ms budget. Evidence:
  `.reports/mobile-audio/reader-relaunch-5E6A9E57-F6A8-43BA-A0E0-B7DE6BA68F0A` and
  `.reports/mobile-audio/reader-relaunch-FF59D9D9-3945-42B9-99A5-B0F907BA7CB2`.

- [x] **APP-20261011-01 — Verify paginated horizontal swipes on the active
  reader.** Root cause was the UI test opening a second copy of the seeded book
  and reading the first matching accessibility identifier, which belonged to a
  hidden reader. The harness now reuses the seeded active reader, chooses the
  visible page indicator and matching pagination probe, retains that page identity
  when chrome hides the indicator, and chooses visible controls for chrome state.
  It taps the existing test-only chrome control (same production action) so EPUB
  links cannot intercept the geometry transition; page turns remain real horizontal
  drags on the visible viewport. Exact iPhone SE (1st generation)/iOS 15.5 run
  passed: LOTR Contents 1/5 -> 2/5 (offset 363), reverse swipe returned to the
  prior page, two chrome hide/show cycles retained `first=0` and `offset=363`, and
  clipping stayed at zero. Confirmed again after reverting all speculative
  production gesture changes. Build and focused UI test passed; 1 test, 0 failures,
  0 skips, `.reports/reader-ios15-5-lotr-unmodified-gestures.xcresult`.
  Attachments: `.reports/reader-ios15-5-lotr-unmodified-gestures-attachments/`.

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
  Exact Simulator verification passed: iPhone SE (1st generation), iOS 15.5,
  UDID `C66CCB36-C43E-4174-861E-2FA713389C84`; one focused XCTest passed with zero
  failures/skips in `.reports/simulator-smoke-07AE4798-69E3-4A99-92EC-FA22233B2E23/tests.xcresult`.
  `testBookDetailActionsKeepMainActorResponsiveWhileOpeningBook` exercises both
  Listen and Download bookmark resolution while the MainActor heartbeat runs;
  it completed in 0.664 s. The app was separately installed and launched with
  `-uiTestFixture`; the seeded library screen was inspected in
  `.reports/book-detail-ios15-5-installed.png` and left open in the Simulator.
  Build used Xcode 16.4 / iOS Simulator SDK 18.5 with deployment target 15.0,
  then ran successfully on the exact iOS 15.5 runtime. This is Simulator runtime
  evidence, not an SDK 15.5 build. No physical iPhone was used. The smoke wrapper
  invokes `/usr/bin/xcrun` and ignores `DEVELOPER_DIR`; the successful run
  supplied the exact Xcode 16.4 `.xctestrun` explicitly through
  `IOS_SIMULATOR_XCTESTRUN_PATH`.
  Native macOS durable-import
  regressions passed 3/3, zero skips in
  `Test-EpubToMp3Mac-2026.10.11_08-03-51--0300.xcresult`. Source-bound projection
  benchmark passed 1/1 and retained hash/timing data in
  `.reports/mobile-audio/reader-relaunch-EF7E0E9F-2D5A-4EF9-8183-CB2B1548E7F2/projection.xcresult`;
  it does not close the 200 ms relaunch gate. Details and exact timing bounds are
  in `docs/plans/2026-10-08-app-quality-performance.md`.
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

- [x] **APP-20261009-44 — Remove generic Simulator load gates.**
  Removed load-average, RAM, memory-pressure and thermal-state refusals from
  local Simulator workflows while retaining single-heavy-job serialization and
  operation timeout. Crash-log basis: two `SimLaunchHost.x86` reports on
  2026-10-09 show `EXC_BAD_ACCESS`/`SIGBUS` in dyld `dlopen` and `dlclose` paths;
  neither report supports a load threshold. Historical CoreSimulator panic
  evidence still supports the existing iOS runtime compatibility ceiling.
  Verification: inspected final diff and crash report exception/thread stacks;
  executable checks not run.

- [x] **APP-20261009-45 — Oldest iOS/Xcode workflow on Intel Mac.** Superseded.
  Follow the authoritative native runtime requirement in `docs/agent-workflow.md`;
  this historical ticket does not define a separate device/runtime rule.

## Historical backlog (requires revalidation; not current platform scope)

The old verification recipes below are historical. Current work follows the
runtime contract in `docs/agent-workflow.md`.

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
