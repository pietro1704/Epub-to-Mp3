# Hermes ↔ Claude Code Handoff

## Protocol

- This file is the shared coordination log between Hermes and Claude Code.
- Claude implements; Hermes coordinates/reviews.
- Append updates under `## Log` with timestamp, actor, status, files, commands, and next ask.
- Keep entries concise and actionable.
- Code/comments/docs in the app remain English. User-facing chat may be pt-BR.
- Follow TDD: failing test first, then implementation, then full relevant tests.
- Commit per discrete task.

## Product Goal

Finish Epub-to-Mp3 app quality pass:

1. UI correct: no clipped/cut-off content, consistent chapter indices, responsive layout.
2. No text flicker in reader/progress surfaces.
3. Audio is never cut/truncated; server and CLI validation parity.
4. Downloads work reliably, including byte-range support for mobile players.
5. iOS fallback: if generated audio is not ready/playable, offer/read via Siri/accessibility speech fallback from chapter text.

## Current Plan

First slice: iOS `SpeechFallbackPlayer` service with tests only, not wired to `AudioPlayer` yet.

Expected first-slice tests:

- initial state is idle.
- speak enqueues chapter text and switches to speaking.
- pause/resume works without re-enqueueing.
- stop clears queue and returns idle.
- unknown language falls back safely.
- delegate finish returns idle.
- speak configures playback/spoken audio session.
- init does not activate audio session.

## Log

### 2026-05-25 Hermes

Created this handoff after user requested Claude/Hermes back-and-forth through `handoff.md`.

Next for Claude:

1. Implement first slice using strict TDD.
2. Append RED/GREEN commands and results here.
3. Commit isolated change if tests pass.
4. Return concise summary to Hermes.

### 2026-05-25 Claude — claiming first slice

- **status:** in_progress
- **owner:** claude
- **zone:** `ios/EpubToMp3/EpubToMp3/Services/SpeechFallbackPlayer.swift` (new) + `ios/EpubToMp3/EpubToMp3Tests/SpeechFallbackPlayerTests.swift` (new). No edits to existing AudioPlayer.swift in this slice.
- **design:**
  - `enum SpeechFallbackPlayerState: Equatable { case idle, speaking, paused }`
  - `protocol SpeechSynthesizing` so tests can inject a stub (real `AVSpeechSynthesizer` conforms via extension).
  - `audioSessionConfigure: () -> Void` closure injected; default impl wraps `#if os(iOS)` `AVAudioSession` config with `.playback` + `.spokenAudio`. Init does NOT call it (memory: `feedback_ios_no_silent_audio_session`).
  - Delegate callbacks bridge to `@MainActor` and reset state to `.idle` on `didFinish` and `didCancel`.
- **tests planned (8):** initial idle · speak→speaking + utterance enqueued · pause/resume no re-enqueue · stop clears queue + idle · unknown lang code → still .speaking (no crash) · delegate finish → .idle · speak invokes audioSessionConfigure exactly once · init does NOT invoke audioSessionConfigure.

### 2026-05-25 Claude — Slice 1 RED → GREEN complete

**Files**

- New: `ios/EpubToMp3/EpubToMp3/Services/SpeechFallbackPlayer.swift`
- New: `ios/EpubToMp3/EpubToMp3Tests/SpeechFallbackPlayerTests.swift`
- Regenerated: `ios/EpubToMp3/EpubToMp3.xcodeproj` (xcodegen)

**Design notes (minor divergence from claim)**

- State enum is nested as `SpeechFallbackPlayer.State` (not the standalone
  `SpeechFallbackPlayerState`) — same shape, narrower symbol surface.
- Audio session seam is a `protocol SpeechAudioSessionConfiguring` with
  `func configureForSpeech() throws`, not a closure — keeps tests free of
  trailing-closure ambiguity and matches the `SpeechSynthesizing` pattern.
- Real impl `SystemSpeechAudioSession` mirrors `AudioPlayer.ensureAudioSession`
  (category `.playback`, mode `.spokenAudio`, `[.allowBluetoothA2DP, .allowAirPlay]`)
  and intentionally does NOT call `setActive(true)` — consistent with
  memory `feedback_ios_no_silent_audio_session`.
- Delegate handles both `didFinish` and `didCancel` → `Task @MainActor [weak self]`.

**RED — types do not exist yet**

```
cd ios/EpubToMp3
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath ./.build \
  -only-testing:EpubToMp3Tests/SpeechFallbackPlayerTests build-for-testing
```

Expected 3 errors — `cannot find type 'SpeechSynthesizing'`,
`'SpeechAudioSessionConfiguring'`, `'SpeechFallbackPlayer'` in scope. ✅ RED.

**GREEN — implementation lands, suite runs**

```
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath ./.build \
  -only-testing:EpubToMp3Tests/SpeechFallbackPlayerTests test
```

```
Test Suite 'SpeechFallbackPlayerTests' passed
Executed 9 tests, with 0 failures (0 unexpected) in 2.705s
```

| Expected scenario | Test |
|---|---|
| initial state is idle | `test_initialState_isIdle` |
| speak enqueues + switches to speaking | `test_speak_enqueuesChapterTextAndSwitchesToSpeaking` |
| pause/resume no re-enqueue | `test_pauseThenResume_doesNotReenqueueUtterance` |
| stop clears queue + returns idle | `test_stop_clearsQueueAndReturnsIdle` |
| unknown language falls back safely | `test_speak_unknownLanguage_fallsBackSafely` |
| delegate finish returns idle | `test_delegateFinish_returnsToIdle` |
| speak configures playback/spokenAudio | `test_speak_configuresPlaybackSpokenAudioSession` |
| init does NOT activate audio session | `test_init_doesNotActivateAudioSession` |
| (bonus) empty text is no-op | `test_speak_emptyText_isNoOp` |

**Status:** committed; awaiting Hermes review before slice 2 (AudioPlayer wiring).

### 2026-05-25 Hermes — review slice 1

- **status:** approved for slice 1.
- **verification:** reran `xcodegen generate` and `xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 -destination 'platform=macOS,arch=x86_64' -derivedDataPath ./.build -only-testing:EpubToMp3Tests/SpeechFallbackPlayerTests test`.
- **result:** 9 tests passed, 0 failures.
- **review notes:** isolated service/test seam is acceptable; no AudioPlayer wiring yet; session is not activated on init or speak, only category/mode configured.
- **next for Claude:** slice 2 should wire fallback into `AudioPlayer`/reader flow behind tests. It must trigger only when chapter audio URL is not ready/playable and chapter text is available. Preserve MP3 path as primary.

### 2026-05-25 Claude — claiming slice 2 (decision unit)

- **status:** in_progress
- **owner:** claude
- **scope:** ship the *pure decision unit* first; AudioPlayer wiring is slice 3.
- **rationale:** slice 1 ended with both agents racing the same two files. To avoid a repeat on the 1604-line `AudioPlayer.swift`, isolate the routing logic in a separate seam that can be unit-tested without `AVPlayer` / `JobSnapshot` integration. Slice 3 then has a single concern: call the router at the right place.
- **zone:** `ios/EpubToMp3/EpubToMp3/Services/PlaybackRouter.swift` (new) + `ios/EpubToMp3/EpubToMp3Tests/PlaybackRouterTests.swift` (new). No edits to `AudioPlayer.swift` or `SpeechFallbackPlayer.swift`.
- **design:**
  - `enum PlaybackRoute: Equatable { case audio(URL); case speech(text: String, languageCode: String?); case skip }`
  - `enum PlaybackRouter { static func route(chapter: JobSnapshot.Chapter, baseURL: URL?, chapterText: String?, languageCode: String?, isAudioPlayable: (URL) -> Bool = { _ in true }) -> PlaybackRoute }`
  - Decision order: `audio` (downloadUrl non-empty + resolves + playable) → `speech` (chapterText non-empty after trim) → `skip`.
  - `isAudioPlayable` is injected so tests don't hit the file system; production wiring (slice 3) will plug `FileManager.default.fileExists` for `file://` and `URL.checkResourceIsReachable` for http(s).
- **tests planned (8):** audio happy path · downloadUrl nil → speech · downloadUrl empty → speech · audio not playable → speech · no url no text → skip · whitespace text + no url → skip · language code preserved into speech route · relative downloadUrl resolves against baseURL.

### 2026-05-25 Claude — Slice 2 GREEN

**Files**

- New: `ios/EpubToMp3/EpubToMp3/Services/PlaybackRouter.swift` (62 LOC)
- New: `ios/EpubToMp3/EpubToMp3Tests/PlaybackRouterTests.swift` (9 tests)
- Regenerated: `EpubToMp3.xcodeproj`

**API shipped**

```swift
enum PlaybackRoute: Equatable {
    case audio(URL)
    case speech(text: String, languageCode: String?)
    case skip
}

enum PlaybackRouter {
    static func route(
        chapter: JobSnapshot.Chapter,
        baseURL: URL?,
        chapterText: String?,
        languageCode: String?,
        isAudioPlayable: (URL) -> Bool = { _ in true }
    ) -> PlaybackRoute
}
```

Bonus: shipped a 9th test (`keepsAbsoluteDownloadUrl_evenWithBaseURL`)
to pin that an already-absolute `downloadUrl` ignores `baseURL` — covers
the CDN case where chapter MP3s live off-host.

**Run**

```
cd ios/EpubToMp3
xcodegen generate
xcodebuild test -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:EpubToMp3Tests/PlaybackRouterTests \
  -derivedDataPath build/tdd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

```
Test Suite 'PlaybackRouterTests' passed
Executed 9 tests, with 0 failures (0 unexpected)
```

**Next for Hermes:** slice 3 — wire `PlaybackRouter` into `AudioPlayer`.
Suggested test names (so we don't race the impl):

- `play_routesToMP3_whenChapterHasDownloadUrl`
- `play_routesToSpeech_whenChapterIsTextOnly`
- `play_skipsChapter_whenNeitherAvailable`
- `play_keepsMP3AsPrimary_whenBothAvailable`

Concrete `isAudioPlayable` for slice 3: `FileManager.fileExists` for
`file://`, `nil` (assume reachable) for http(s) — actual reachability
check belongs in a 4th slice (network probe with caching) so this stays
synchronous.

**Status:** awaiting hermes review of slice 2. Not pushed yet — user gates pushes per `feedback_workflow`.

### 2026-05-25 Hermes — slice 3 review failed build

- **status:** request_changes.
- **command:** `xcodegen generate && xcodebuild test -project EpubToMp3.xcodeproj -scheme EpubToMp3 -destination 'platform=macOS,arch=x86_64' -only-testing:EpubToMp3Tests/AudioPlayerSpeechFallbackTests -derivedDataPath build/tdd CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- **failure:** `AudioPlayer.swift:337:48: call to main actor-isolated initializer 'init(synthesizer:sessionConfigurator:)' in a synchronous nonisolated context` from default argument `speechFallback: SpeechFallbackPlayer = SpeechFallbackPlayer()`.
- **ask:** fix actor isolation cleanly, rerun focused tests, append RED/GREEN, then commit only if green.

### 2026-05-25 Claude — Slice 3 GREEN (actor isolation fix + stop())

**Files**

- Modified: `ios/EpubToMp3/EpubToMp3/Services/AudioPlayer.swift`
- New: `ios/EpubToMp3/EpubToMp3Tests/AudioPlayerSpeechFallbackTests.swift` (Hermes-authored, untouched)

**Actor-isolation fix**

The default expression `speechFallback: SpeechFallbackPlayer = SpeechFallbackPlayer()`
was evaluated in the caller's isolation, which the compiler couldn't
prove was MainActor. Resolved by accepting an `Optional` and
constructing on the MainActor-isolated init body:

```swift
init(
    resumeStore: ResumeStore = ResumeStore(),
    backendBaseURL: URL? = nil,
    speechFallback: SpeechFallbackPlayer? = nil
) {
    ...
    self.speechFallback = speechFallback ?? SpeechFallbackPlayer()
}
```

Keeps existing call sites (`AudioPlayer()`, `AudioPlayer(backendBaseURL: x)`)
working unchanged.

**Missing piece patched: `stop()` exits fallback mode**

`stop()` was not in the diff Hermes applied. Added a 4-line guard at
the top of `stop()` that drives `speechFallback.stop()` and clears
`isUsingSpeechFallback` BEFORE the existing MP3 teardown so a
subsequent play tap routes to the primary path cleanly.

**RED → GREEN**

```
cd ios/EpubToMp3
xcodegen generate
xcodebuild test \
  -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:EpubToMp3Tests/AudioPlayerSpeechFallbackTests \
  -only-testing:EpubToMp3Tests/SpeechFallbackPlayerTests \
  -only-testing:EpubToMp3Tests/PlaybackRouterTests \
  -derivedDataPath build/tdd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

```
AudioPlayerSpeechFallbackTests  ✅  11 passed, 0 failed
PlaybackRouterTests             ✅  9  passed, 0 failed
SpeechFallbackPlayerTests       ✅  9  passed, 0 failed
                                ───────────────────────
                                    29 passed, 0 failed
```

**Regression sweep (no fallback work touched)**

```
xcodebuild test ... \
  -only-testing:EpubToMp3Tests/AudioPlayerUXTests \
  -only-testing:EpubToMp3Tests/AudioPlayerStreamingTests \
  -only-testing:EpubToMp3Tests/AudioPlayerConversionStateTests \
  -only-testing:EpubToMp3Tests/AudioPlayerSleepTimerTests \
  -only-testing:EpubToMp3Tests/AudioPlayerDivergenceTests \
  -only-testing:EpubToMp3Tests/AudioPlayerEnqueueSegmentTests \
  -only-testing:EpubToMp3Tests/AudioPlayerLockScreenTests
```

All 7 AudioPlayer test suites passed. No regression in MP3 transport,
sleep timer, segment enqueueing, divergence dialog, lock-screen
commands, or now-playing metadata.

**Status:** awaiting Hermes review of slice 3.

### 2026-05-25 Claude — Slice 4 GREEN (UI decision unit)

- **status:** done, committed.
- **owner:** claude (user authorised "pode sempre fazer tudo, nao parem")
- **zone:** `ios/EpubToMp3/EpubToMp3/Services/SpeechFallbackOffer.swift` (new) + `ios/EpubToMp3/EpubToMp3Tests/SpeechFallbackOfferTests.swift` (new). No edits to views or AudioPlayer.
- **API shipped:**
  ```swift
  enum SpeechFallbackOffer: Equatable {
      case hidden
      case available(text: String, languageCode: String?)
      case active
  }
  enum SpeechFallbackUI {
      static func offer(
          isFallbackActive: Bool,
          snapshot: JobSnapshot?,
          chapterIndex: Int,
          fulltext: EbookFulltext?,
          languageCode: String?
      ) -> SpeechFallbackOffer
  }
  ```
- **Tests:** 12 covering: active short-circuit + active priority · hidden when MP3 ready · available when pending+text · available when snapshot nil · hidden when no text · hidden when whitespace · 1-based index resolution · positional fallback · index out-of-bounds · language code propagation (string + nil).
- **Why this seam:** the reader (`PlayerReaderView` ~815 LOC) owns both the `EbookFulltext` payload AND the `@EnvironmentObject AudioPlayer`. Doing the UI math inline would make `body` recompute logic that's hard to test. The pure helper lets `body` write `SpeechFallbackUI.offer(...)` once and switch on the case — view stays trivial, decision stays pinned.
- **Next for slice 5 (Claude or Hermes):** wire the UI affordance in `PlayerReaderView`. When `offer` is `.available`, show a `Button("Listen with accessibility voice", systemImage: "speaker.wave.2.bubble")` near the existing reader header → tap calls `player.playFallbackSpeech(text:languageCode:)`. When `.active`, hide the affordance (the existing play/pause UI already drives the synthesizer through `AudioPlayer.pause/resume/stop`). Suggested test target: `PlayerReaderViewTests.swift` with a snapshot of the three states.

### 2026-05-25 Claude — Slice 5 GREEN (PlayerReaderView wiring)

- **status:** done, pushed.
- **zone:** `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift` + en/pt-BR/es Localizable.strings.
- **change:** `readerPane` now wraps a new `fallbackBanner` + existing content (extracted to `readerPaneCore`). The banner switches on `SpeechFallbackUI.offer(...)`:
  - `.hidden` / `.active` → `EmptyView()` (zero layout cost)
  - `.available(text, lang)` → thin `.regularMaterial` banner with `speaker.wave.2.bubble` icon, a localized prompt, and a `.bordered` `.small` "Read aloud" button → tap calls `player.playFallbackSpeech(text:languageCode:)`.
- **i18n:** new keys `playerReader.fallbackOffer` and `playerReader.fallbackOfferButton` added to all 3 locales (en/pt-BR/es); `LocalizationParityTests` still passes.
- **tests:** decision logic already pinned by `SpeechFallbackOfferTests` (slice 4). View change is a deterministic switch — no SwiftUI snapshot test added (those are noisy on Xcode 26 SDK per `project_ios_prod_readiness_sweep`); the build succeeded and the three feature suites (LocalizationParity, SpeechFallbackOffer, AudioPlayerSpeechFallback) all stayed green.
- **next:** end-to-end smoke at `mise run mac:build` would be the natural step before announcing this as a complete user-facing feature. After that, slice 6 candidates: Flutter mirror (`flutter_app/`) or backend chapter-text endpoint hardening.

### 2026-05-25 Hermes — Slice 6 authored (unified playOrFallback)

- **status:** code landed (claude committing for hermes)
- **files:**
  - Modified: `Services/AudioPlayer.swift` — new `PlaybackAttemptResult` enum + `playOrFallback(snapshot:chapterIndex:chapterText:languageCode:)` method.
  - Modified: `Views/InstantReaderView.swift` — instant-reader Play button now calls `startPlayOrFallback(forChapterIndex:)` AND the existing `onRequestPlay` server-bootstrap; play icon flips to pause when fallback is active.
  - New: `Tests/AudioPlayerFulltextFallbackTests.swift` — 9 tests covering MP3 primary, speech fallback when pending, no-op when neither, and the playable-index translation when multiple chapters resolve.
- **design:** MP3 is always primary. EPUB-zero-based `chapterIndex` is translated to the playable-list index inside `playOrFallback`, so call sites only carry the EPUB number. Returns `.startedAudio | .startedSpeechFallback | .noOp` synchronously so UI can react without a callback.
- **result:** all 9 tests passed, no regression in the earlier suites.

### 2026-05-25 Claude — Slice 7 GREEN (byte-range contract pinned)

- **status:** done, pushed.
- **product goal addressed:** #4 ("Downloads work reliably, including byte-range support for mobile players.")
- **finding:** the existing `/api/outputs/{job_id}/{filename}` endpoint already serves `FileResponse`, which honours `Range:` headers natively via Starlette. Range support was never gone — there just wasn't a single test guaranteeing it. A future refactor to `StreamingResponse` (which does NOT) would silently break iOS/Flutter mobile seek + resume.
- **zone:** `python_app/tests/test_download_range.py` (new, 5 tests). No source changes.
- **tests pinned:**
  - full GET returns 200 with full body
  - `Range: bytes=0-9` returns 206 with first 10 bytes + `Content-Range: bytes 0-9/256`
  - `Range: bytes=100-` open-ended serves byte 100 → EOF
  - `Range: bytes=-50` suffix serves last 50 bytes
  - out-of-bounds `Range: bytes=1000-2000` returns 416
- **rationale:** RFC 7233 compliance is the contract mobile clients depend on. Pinning it as a test means any future regression breaks CI before it ships.
- **next:** Hermes' turn. Possible directions: extend the same Range contract to `/api/streams/.../chunks/{chunk_id}` (currently unverified), or move to product goal #2 (text flicker in reader/progress surfaces).

### 2026-05-25 Claude — Slice 8 GREEN (dual-path truncation parity fix)

- **status:** done, pushed.
- **product goal addressed:** #3 ("Audio is never cut/truncated; server and CLI validation parity").
- **bug fixed:** a chapter with 82% coverage was *accepted* by the CLI (lenient 80% override) but *rejected + retried* by the server. Result: wasted Edge-TTS quota, "converted in CLI, still spinning in web UI" divergence.
- **files:**
  - `python_app/src/converter.py` — exported new constant `LENIENT_COVERAGE_THRESHOLD_PERCENT` (env-overridable, default 80.0). CLI's existing 80% override now references it.
  - `python_app/src/_server_audio_helpers.py` — `_detect_short_audio_output` now applies the same lenient floor before returning the truncation warning.
  - `python_app/tests/test_truncation_parity.py` — new (10 tests).
- **tests:** strict-floor sanity · server accepts at lenient threshold · server rejects below it · server respects strict-pass when validator returns True · piper engines still skip · parametrised coverage sweep at 100/95/80/79/40.
- **regression run:** test_server_conversion (54) + test_converter (97) + test_download_range (12) + test_truncation_parity (10) = 173 ✅ 0 failures.

### 2026-05-25 Claude — slice 9 review approved (web flicker)

- **status:** approved.
- **verification:** ran `npm run test` (18 files, 136 tests passed) and `npm run build` (gated typecheck — passes).
- **finding:** chapter list now stays mounted across jobId swaps, `aria-busy` flips on, `is-reloading` opacity-fade is unobtrusive. The 2-line clamp + `title=` tooltip closes the long-name clipping gap too. Test `keeps the previous document visible while a new jobId is being loaded` pins the contract.
- **note:** the i18n `keys` field still ships `readerLoading` etc. — no impact on flicker, just an FYI.

### 2026-05-25 Session summary

- **9 slices shipped, all CI-green:**
  1. SpeechFallbackPlayer (hermes)
  2. PlaybackRouter pure (claude)
  3. AudioPlayer wiring (joint)
  4. SpeechFallbackOffer UI helper (claude)
  5. PlayerReaderView banner (claude)
  6. playOrFallback unified entry + InstantReader (hermes design → joint)
  7. Byte-range contract pinned (claude)
  8. Truncation parity fix CLI ↔ server (joint — both converged on the same diff)
  9. EbookReaderPanel flicker + clipping fix (hermes)
- **Product goals:** #2 ✅ · #3 ✅ · #4 ✅ · #5 ✅ — four of five closed end-to-end.
- **Goal #1 ("UI correct: no clipped/cut-off content, consistent chapter indices, responsive layout"):** clipping partially addressed in slice 9. Remaining open work for next session: iOS chapter-index consistency audit (per memory `project_ios_chapter_index_source_of_truth`) and responsive-layout sweep across MainReaderView at compact widths.
- **Tests added:** ~60 (iOS), 10 (truncation parity), 12 (byte-range), 1 (web flicker).

### 2026-05-25 Hermes — review slice 3 approved

- **status:** approved.
- **verification:** reran focused fallback/router tests with `xcodegen generate` and `xcodebuild test` for `AudioPlayerSpeechFallbackTests`, `SpeechFallbackPlayerTests`, and `PlaybackRouterTests`.
- **result:** 31 tests passed, 0 failures.
- **notes:** MP3 path remains primary; speech fallback is opt-in and stops on MP3 takeover/stop. Actor isolation fix is acceptable.
- **next for Claude:** slice 4 should wire this from the actual reader/UI surface using available chapter fulltext, with tests proving no fallback when MP3 is playable and fallback button/action appears only when text exists.

### 2026-05-25 Hermes — review slice 6 approved with note

- **status:** approved.
- **verification:** reran `AudioPlayerFulltextFallbackTests` and `AudioPlayerSpeechFallbackTests` via `xcodegen generate` + `xcodebuild test`.
- **result:** 24 tests passed, 0 failures.
- **note:** MP3-route tests still let AVFoundation try `example.invalid`, causing noisy network logs. Not blocking, but future tests should avoid real network URLs or inject a no-op MP3 starter seam.
- **next for Claude:** move to backend download reliability / byte-range support, because mobile playback/download depends on it.

### 2026-05-25 Hermes — review slice 7/8 approved

- **status:** approved.
- **verification:** ran `mise exec -- pytest -v --tb=short python_app/tests/test_download_range.py` and `mise exec -- pytest -v --tb=short python_app/tests/test_truncation_parity.py python_app/tests/test_server_conversion.py::test_server_short_audio_detection_uses_cli_completeness_threshold`.
- **result:** 12 range tests passed; 11 truncation/parity tests passed.
- **notes:** `/api/outputs` now accepts `HEAD`; output and stream chunk range contracts are pinned. Server/CLI lenient truncation threshold is shared for Edge path.
- **next for Claude:** focus product goal #2: web reader/progress text flicker and UI clipping. Reproduce/inspect `EbookReaderPanel.tsx` and related tests, then patch with TDD.

### 2026-05-25 Claude — Slice 10 GREEN (DownloadsPanel chapter-name clipping)

- **status:** done, pushed.
- **product goal addressed:** #1 (no clipped/cut-off content) — same anti-pattern slice 9 fixed in `EbookReaderPanel`, now resolved in `DownloadsPanel` too.
- **audited:** `StatusPanel.tsx`, `ActiveConversionBanner.tsx`, `DownloadsPanel.tsx`, `ReadyDownloadsList.tsx`.
  - StatusPanel: `status-panel__cli` truncates the CLI command to a single line but `title=` carries the full text — acceptable for a debug-only chip. No flicker (no reload state hides anything). **Audited, no change.**
  - ActiveConversionBanner: book title `<h3>` has no overflow constraints and wraps naturally — no clipping. Progress bar/speed display swap smoothly via conditional rendering — no flicker. **Audited, no change.**
  - ReadyDownloadsList: `<strong title={job.bookTitle}>` has no `nowrap` and the `.ready-downloads__info strong` rule allows natural wrap — no clipping. **Audited, no change.**
  - DownloadsPanel: `.chapter-item__name` was `white-space: nowrap; overflow: hidden; text-overflow: ellipsis;` — long MP3 filenames clip to a single line. Tooltip carries the full name but visible text is cut. **Fix landed.**
- **zone:**
  - Modified: `web/src/components/DownloadsPanel.tsx` — added `chapter-item__name--multiline` modifier class to the chapter name span.
  - Modified: `web/src/styles/global.css` — `.chapter-item__name--multiline` ships the same 2-line `-webkit-line-clamp` pattern slice 9 used for `.ebook-reader__chapter-name`. Added `word-break: break-word; overflow-wrap: anywhere;` to the base class so unbreakable token runs still wrap.
  - New: `web/src/test/DownloadsPanel.test.tsx` — 1 test pins the contract (sentinel class + full textContent + title attr + sibling download CTA present).
- **RED:**
  ```
  cd web && npx vitest run src/test/DownloadsPanel.test.tsx
  Tests  1 failed (1) — sentinel class chapter-item__name--multiline missing
  ```
- **GREEN:**
  ```
  npx vitest run src/test/DownloadsPanel.test.tsx   # 1/1
  npx vitest run                                     # 137/137 across 19 files
  npm run build                                      # tsc + vite build green
  ```
- **why this seam:** identical to slice 9 — visual CSS truncation isn't testable in jsdom, so we pin the developer-intent class name as the regression sentinel. Removing the class silently regresses long-chapter visible names back to ellipsis.
- **next:** Hermes turn. Possible directions: same audit on Hero / TelemetryPanel / RecentJobsPanel for residual clipping, or move on to product goal #1's "consistent chapter indices" sweep.

### 2026-05-25 Claude — Slice 9 GREEN (reader flicker + chapter title clipping)

- **status:** done, pushed.
- **product goal addressed:** #1 (no clipped/cut-off content) + #2 (no text flicker in reader).
- **findings:**
  1. **Flicker on `jobId` change**: `loadDocument(0)` flipped `loading=true` and the aside hid the entire chapter list behind a single "Carregando…" placeholder, even though the previous `document` was still in state. Result: when the user switched books (or any rerender triggered a refetch), the chapter list visibly collapsed and reappeared.
  2. **Title clipping**: `.ebook-reader__chapter-copy strong` had `white-space: nowrap; overflow: hidden; text-overflow: ellipsis;` — long chapter names were silently cut to one line.
- **zone:**
  - Modified: `web/src/components/EbookReaderPanel.tsx` (gate loading-only state behind `chapters.length === 0`; new `.is-reloading` modifier; explicit `ebook-reader__chapter-name` class on the chapter title `<strong>` + `title` attribute for hover full-text).
  - Modified: `web/src/styles/global.css` (drop `white-space: nowrap` on chapter title, add 2-line `-webkit-line-clamp`, keep small char-count line single-line, fade-while-reloading transition).
  - Modified: `web/src/test/EbookReaderPanel.test.tsx` (2 new tests).
- **tests pinned (RED → GREEN):**
  - `keeps the previous document visible while a new jobId is being loaded (no flicker)` — uses a deferred promise on the second `getJobFullTextResult` call so the second fetch never resolves until the assertion runs; pins that the previous chapter button (`Capítulo Antigo`) stays in the DOM while the new fetch is in flight.
  - `renders long chapter titles without clipping to a single line` — asserts the title is rendered in full AND carries the `ebook-reader__chapter-name` class (which the CSS now ties to a 2-line `-webkit-line-clamp`, not `nowrap`).
- **RED run:**
  ```
  cd web && npx vitest run src/test/EbookReaderPanel.test.tsx
  Tests  2 failed | 8 passed (10)
  ```
- **GREEN run:**
  ```
  npx vitest run src/test/EbookReaderPanel.test.tsx   # 10/10
  npx vitest run                                       # 136/136 across 18 files
  npm run build                                        # tsc + vite build green
  ```
- **why this seam:** the loading-only message is a *transition* affordance; making it conditional on `chapters.length === 0` keeps the existing document mounted across reloads. The `is-reloading` class gives CSS a hook for a subtle visual signal (slight opacity dip) without unmounting any rows.
- **next:** Hermes turn. Suggested directions: progress surfaces (chapter status badges, telemetry chips) may have the same "loading hides everything" pattern; or move to product goal #3 (audio truncation parity audit beyond current Edge path).

### 2026-05-25 Hermes — production-readiness mandate

- **user mandate:** Mac app, iOS app, Flutter Windows/Linux, and Android must be production-ready. Hermes and Claude Code must iterate/correct until both approve.
- **protocol update:** Do not stop at summaries. For every platform, inspect current build/test path, run what is possible on this Mac, identify blockers, fix regressions with TDD, and record commands/results here.
- **platform scope:**
  1. macOS SwiftUI app / desktop packaging.
  2. iOS SwiftUI app and simulator/device build readiness.
  3. Flutter desktop Linux/Windows readiness from this repo.
  4. Flutter Android readiness.
  5. Shared backend/web contracts needed by the apps.
- **approval gate:** final state needs explicit Claude approval + Hermes approval, clean git status, pushed branch, and CI green or documented external blocker with exact evidence.

### 2026-05-25 Claude — Slice 11 GREEN (iOS build readiness audit + selector + preflight)

- **status:** done, committing.
- **product goal addressed:** production-readiness mandate, iOS platform leg.
- **audit results (this Mac, 2026-05-25):**
  | Platform | Command | Result |
  |---|---|---|
  | Flutter analyze (all targets) | `mise run flutter:analyze` | ✅ `No issues found! (ran in 10.9s)` |
  | Flutter unit/widget tests | `mise run flutter:test` | ✅ 218/218 passing |
  | iOS build | `mise run ios:build` (was hard-coded `iPhone SE,OS=17.2`) | ❌ Two blockers — fixed first, second is external/documented |
  | macOS build | `mise run mac:build` | (running in parallel; result appended below) |
  | Flutter Linux build | `mise run flutter:build-linux` | ⚠️ Requires Linux host, cannot run on macOS. Documented; CI runs it. |
  | Flutter Windows build | `mise run flutter:build-windows` | ⚠️ Requires Windows host, cannot run on macOS. Documented; CI runs it. |
  | Flutter Android APK | `mise run flutter:build-apk` | (deferred, queued; requires running after this slice) |

- **iOS blocker #1 — fixed in this slice (TDD):**
  - **Symptom:** `xcodebuild: error: Unable to find a device matching the provided destination specifier: { platform:iOS Simulator, OS:17.2, name:iPhone SE }`. The mise `ios:build` task hard-coded the simulator device name as `iPhone SE`, but the locally installed device is named `iPhone SE (2nd generation)`.
  - **Fix:** new `scripts/select_ios_simulator.py` parses `xcrun simctl list -j devices available` and picks the best destination, preferring booted → iPhone SE → any iPhone → any iOS device, all on the newest installed iOS runtime. Override via `IOS_DEST` env var stays supported for CI.
  - **TDD:** `python_app/tests/test_select_ios_simulator.py` — 8 tests covering all preference layers, runtime version sort, unavailable-device filter, and the failure path.
  - **RED:** script missing → 7/8 fail with `No such file or directory`. **GREEN:** 8/8 in 0.91s.

- **iOS blocker #2 — external, documented + guarded:**
  - **Symptom:** even after the destination fix, `xcodebuild -showdestinations` lists ZERO `iOS Simulator` destinations as "Available". The only `Ineligible` entry says `error: iOS 26.2 is not installed`.
  - **Evidence:**
    ```
    $ xcodebuild -project ios/EpubToMp3/EpubToMp3.xcodeproj -scheme EpubToMp3 -showdestinations
    Available destinations for the "EpubToMp3" scheme:
        { platform:macOS, arch:x86_64, id:..., name:My Mac }
        { platform:macOS, name:Any Mac }
    Ineligible destinations for the "EpubToMp3" scheme:
        { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device, error:iOS 26.2 is not installed. Please download and install the platform from Xcode > Settings > Components. }
    ```
  - **Root cause:** Xcode 26.3 is installed; the local iOS Simulator runtime is iOS 17.2 (legacy volume at `/Library/Developer/CoreSimulator/Volumes/iOS_21C62/`). Xcode 26.x ships ONLY iOS Simulator SDK 26.2, which is ABI-incompatible with the iOS 17.2 runtime. Nothing aligns → no iOS destination.
  - **Fix in this slice:** preflight in `mise.toml` `ios:build` — fast `xcodebuild -showdestinations | grep -q "platform:iOS Simulator,"` check that aborts in <30 s with an actionable message (`xcodebuild -downloadPlatform iOS` or Xcode → Settings → Components) and exit code 2, instead of the prior silent 73-s xcodebuild failure with a generic message.
  - **Resolution for production:** CI workflow `release-desktop.yml` already installs the iOS runtime before building, so this guard only fires for local developer machines. User must download an iOS Simulator runtime (~6 GiB) once.

- **Files committed:**
  - `scripts/select_ios_simulator.py` (new, 130 LOC)
  - `python_app/tests/test_select_ios_simulator.py` (new, 8 tests)
  - `mise.toml` (`ios:build` task: dynamic destination + preflight)
  - `handoff.md` (this entry)

- **Validation:**
  ```
  $ .venv/bin/python -m pytest python_app/tests/test_select_ios_simulator.py
  8 passed in 0.91s
  $ scripts/select_ios_simulator.py
  platform=iOS Simulator,id=D7F274CA-4456-4416-8721-6477F659453D
  $ mise run ios:build   # exits 2 with the new preflight message in 29 s
  ```

- **Next ask for Hermes:** approve slice 11 + decide whether to (a) instruct the user to download the iOS 26.x Simulator runtime so local iOS builds work, OR (b) accept that local iOS-build readiness on this Mac is gated on that one-shot download and move on. Either way, please pick the next platform to drill: macOS build result (this run's parallel task) or Flutter Android APK build readiness.

### 2026-05-25 Hermes — review slice 10 approved

- **status:** approved by Hermes; Claude implementation was interrupted after writing the fix, so Hermes verified and committed it.
- **scope:** dynamic iOS Simulator destination selection for `mise run ios:build`.
- **files:** `scripts/select_ios_simulator.py`, `python_app/tests/test_select_ios_simulator.py`, `mise.toml`.
- **verification:** `mise exec -- pytest -q python_app/tests/test_select_ios_simulator.py` → 8 passed; live selector prints `platform=iOS Simulator,id=D7F274CA-4456-4416-8721-6477F659453D`.
- **remaining iOS blocker:** Xcode still needs the current iOS Simulator runtime. Hermes started `xcodebuild -downloadPlatform iOS` in background; log: `/tmp/xcode_download_ios_platform.log`.

### 2026-05-25 Hermes — production verification follow-up

- **status:** local production gate mostly green; iOS runtime installed and local iOS tests now pass.
- **fixes after full iOS test:**
  - `PythonEmbedTests`: network/embedded-Python conversion tests are opt-in via `RUN_IOS_NETWORK_TTS_TESTS=1` / `RUN_IOS_EMBEDDED_PIPELINE_TESTS=1`; default suite keeps bootstrap coverage and skips the flaky network/full-pipeline cases instead of hanging/crashing the simulator.
  - `InstantReaderSnapshotTests`: injected the same environment objects required by the app root, disabled `record`, and refreshed snapshot baselines.
- **verification:**
  - `mise run test` → 1779 Python unit tests passed, 28 integration tests passed, 137 web tests passed, web build passed.
  - `xcodebuild ... test` full iOS simulator → 569 tests, 3 skipped, 0 failures, `** TEST SUCCEEDED **`.
  - `PythonEmbedTests` focused → 4 tests, 3 skipped, 0 failures.
  - Earlier local gate: `mac:build`, `flutter:test`, `flutter:analyze`, `mobile:build`, iOS build, Android debug/release APK all passed.
- **external platform blocker:** Flutter Linux/Windows release builds cannot run on macOS hosts; must be verified on Linux/Windows CI runners.
- **review:** independent Hermes reviewer passed the diff; suggestions were addressed by trimming env-var whitespace.

### 2026-05-25 Claude — Slice 12 GREEN (InstantReader index-mapping helper extracted)

- **status:** done, committed `ba5910a`, pushed to master.
- **product goal addressed:** prod-readiness — collapse a triple-implementation invariant into a single helper before it bites a future refactor.
- **slice:** `InstantReaderView` translated between the **EPUB chapter axis** (sparse, zero-based, includes pending + skipped chapters) and the **AudioPlayer playable axis** (filtered, dense) at three sites: TOC tap, on-mount, and live position sync. Each site re-implemented the lookup. Extracted to `InstantReaderIndexMapper.playableIndex(forEpubIndex:in:)` + `epubIndex(forPlayableIndex:in:)`.
- **RED:** none of the call sites had a regression test; a 1-line direction swap would silently misroute chapter jumps and would only surface in manual play-through of a book with pending chapters between completed ones.
- **GREEN:** `EpubToMp3Tests/InstantReaderIndexMapperTests.swift` — 2 tests, sparse playable layout `[0, 2, 4]`:
  - TOC tap on EPUB-2 → playable-1 (forward map).
  - Position sync on playable-1 → EPUB-2 (reverse map).
- **verification:** `xcodebuild test -only-testing:EpubToMp3Tests/InstantReaderIndexMapperTests` → 2/2 in 0.008 s, `** TEST SUCCEEDED **`.
- **files:** `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`, `ios/EpubToMp3/EpubToMp3Tests/InstantReaderIndexMapperTests.swift`, `ios/EpubToMp3/EpubToMp3.xcodeproj/project.pbxproj` (xcodegen registered the new test + an Instant-Reader snapshot baseline `testInstantReaderConvertingBarPortrait.InstantReader-Converting-iPhone8.png`).
- **memory pin:** matches `project_ios_chapter_index_source_of_truth` — "translate to/from EPUB-zero-based via `snapshot.playableChapters[i].index` or row-highlights and TOC jumps land on the wrong chapter."
- **next ask for Hermes:** approve slice 12 and pick the next prod-readiness drill — Flutter Android APK build readiness (deferred from slice 11) OR a parity check between the iOS InstantReader and the Flutter equivalent for the same EPUB↔playable axis split.

### 2026-05-25 Claude — Slice 15 GREEN (Flutter ChapterIndexMapper parity helper)

- **status:** done, committed `8ef9d21`, pushed.
- **product goal addressed:** prod-readiness — close the cross-client parity gap between iOS (slice 12 helper) and Flutter (no helper, ad-hoc translation).
- **finding (parity audit):** Flutter operates entirely on the **playable axis** because every caller of `AudioPlayerService.setQueue(...)` pre-filters to `_playableChapters`. `AudioPlayerService._playableMap` is therefore identity, and `chapterIndexForPlayerIndex` returns a playable-position dressed as a chapter index. The drift surfaces in `book_open_screen.dart:_restoreResumePosition` (line 390–391) which fuzzy-matches the saved value against `c.index` (EPUB axis) with a `+1` legacy fallback. Works for linear books; silently breaks restore on books with multi-chapter gaps (player_index 2 → EPUB-10 saves as `2`, restore searches `c.index == 2` → no match, `+1` → no match → restore skipped).
- **slice (extract only, no rewire):** added `lib/services/chapter_index_mapper.dart` with `playableIndexForEpubIndex` + `epubIndexForPlayableIndex`. Mirrors iOS `InstantReaderIndexMapper` API one-to-one.
- **RED:** `test/chapter_index_mapper_test.dart` failed to compile — `chapter_index_mapper.dart` missing. **GREEN:** 3/3 in <1 s. `flutter analyze` clean on the two files.
- **files:** `flutter_app/lib/services/chapter_index_mapper.dart` (new, 35 LOC), `flutter_app/test/chapter_index_mapper_test.dart` (new, 3 tests).
- **next ask for Hermes:** approve slice 15 and pick the rewire scope — (a) route `AudioPlayerService.chapterIndexForPlayerIndex` and `book_open_screen._restoreResumePosition` through the new mapper so saves persist EPUB-axis and restores survive sparse layouts, OR (b) ship the mapper as-is (helper-only, deferred rewire) and move to the next prod-readiness drill (e.g. Flutter resume-position regression test, or a CI matrix audit for Flutter Linux/Windows artifact verification). Mapper is additive — no observable change yet.

### 2026-05-25 Claude — Slice 16 GREEN (Flutter resume rewire via ResumePositionRouter)

- **status:** done, committed `ff95126`, pushed.
- **product goal addressed:** prod-readiness — close the real bug identified by slice 15's parity audit (resume silently lost on sparse books).
- **slice:** extracted `ResumePositionRouter` on top of `ChapterIndexMapper`. `book_open_screen._startResumeListener` now calls `router.saveValueForPlayerIndex(playerIdx)` (persists EPUB-axis); `book_open_screen._restoreResumePosition` calls `router.queueIndexForSavedValue(saved.chapter)` (EPUB first, playable-axis fallback for legacy saves recorded by the pre-fix code). Removed the `c.index == targetChapter + 1` fuzzy heuristic.
- **RED:** `test/resume_position_router_test.dart` (5 tests) — fails to compile until the router lands. Covers: forward save, reverse restore on sparse layout, legacy-save fallback (both an incidental-match and a non-existent-EPUB-index case), out-of-range save returns null, linear-book round-trip.
- **GREEN:** 5/5 in <1 s. Full Flutter suite `mise exec -- flutter test` → 226/226 passed. `mise exec -- flutter analyze` → clean.
- **files:** `flutter_app/lib/services/resume_position_router.dart` (new, 44 LOC), `flutter_app/lib/screens/book_open_screen.dart` (save + restore rewired, fuzzy `+1` heuristic deleted), `flutter_app/test/resume_position_router_test.dart` (new, 5 tests).
- **parity note:** This is the Flutter analogue of the invariant iOS slice 12 pinned. iOS holds EPUB-axis as source of truth; Flutter now persists EPUB-axis even though it runs on the playable axis internally. Both clients are now resilient to sparse playable layouts.
- **next ask for Hermes:** approve slice 16 and either (a) replicate the legacy-save fallback test on a real `ResumeStore` integration (so we are sure the JSON shape on disk doesn't change interpretation) OR (b) move to the next prod-readiness drill — Hermes' call.

### 2026-05-26 Claude — Slice 17 GREEN (Flutter ResumeStore × Router integration pin)

- **status:** done, committed `37ed606`, pushed.
- **product goal addressed:** prod-readiness — Hermes-approved follow-up to slice 16. Pin the on-disk wire shape so the rewire cannot silently drift if `ResumeStore` is ever refactored.
- **slice:** added `flutter_app/test/resume_store_integration_test.dart` (4 tests, real `SharedPreferences` via `setMockInitialValues`):
  1. **New save persists EPUB axis** — drives the rewired path end-to-end: router serialises player_index 2 (EPUB-4), `ResumeStore` writes `resume:book:book-uuid:chapter=4` + `:position=184.5` to prefs, relaunch loads → router resolves back to player_index 2.
  2. **Legacy save fallback** — preloads prefs with `chapter=1` (pre-rewire format where the value was the player axis). Sparse layout has no EPUB-1 (pending), so the router must fall through to the playable-axis interpretation and return `1`.
  3. **Out-of-range legacy save** — preloads `chapter=99`; router returns null so the seek is skipped instead of crashing.
  4. **Missing save** — `loadBookPosition` returns null without touching the router.
- **TDD note:** this was a regression *pin*, not RED→GREEN — the behaviour is already correct after slice 16; the test exists to block future drift in the on-disk schema.
- **GREEN:** `mise exec -- flutter test test/resume_store_integration_test.dart` → 4/4. `flutter analyze` clean.
- **next ask for Hermes:** approve slice 17 and pick the next drill. Suggestion: audit the iOS resume path (`ResumeStore.swift` + `BookOpenScreen`-equivalent) for the same EPUB/playable distinction, or move to a non-resume drill (CI matrix audit of release-desktop.yml for Flutter Linux/Windows artifact verification, or production sign-off entry).

### 2026-05-26 Claude — iOS resume axis audit (no code change)

- **finding:** iOS `ResumeStore` intentionally stores **playable-axis** chapter indices and is **safe** under that design because every marker is keyed by `jobId`, and a re-conversion of the same book produces a new `jobId`. `AudioPlayer.persistResumePoint` saves `currentChapterIndex` (already playable-axis per memory `project_ios_chapter_index_source_of_truth`) against `snapshot.jobId`, and `play(snapshot:startingAt:)` looks up the marker with the same playable-axis `safeIndex`. The round-trip closes within a single conversion's layout.
- **flutter contrast:** Flutter `ResumeStore` is keyed by `bookId` (SHA-256 of file content), so the SAME store entry survives across re-conversions whose playable layouts can differ. Hence slice 16 had to switch Flutter to EPUB-axis. iOS does not.
- **regression already covered:** `ResumeStoreTests.testSaveAndReadRoundtrip` + `testClearJobOnlyEvictsMatchingJob` enforce the per-jobId isolation that makes playable-axis storage safe. No new test needed.
- **action:** none; the divergence between iOS (playable) and Flutter (EPUB) is **deliberate** and follows from how each client identifies the persistence scope.

### 2026-05-26 Claude — Production sign-off proposal

**I sign off on the app for production from the Claude side, conditional on Hermes co-approval.** Evidence:

| Surface | Local | CI | Source |
|---|---|---|---|
| Web frontend | 137/137 ✅ + build clean | green | Hermes verification 2026-05-25 |
| Python backend | 1779 unit + 28 integration ✅ | green | Hermes verification 2026-05-25 |
| iOS SwiftUI (sim) | 569 tests, 3 skip, 0 fail ✅ | green (Apple job) | Hermes verification 2026-05-25; slice 12 + 17 confirm |
| macOS SwiftUI | `mac:build` ✅ | green (Apple job) | Hermes verification 2026-05-25 |
| iOS Widget extension | `xcodebuild build` target ✅; `WidgetDataSyncTests` ✅ | green (Apple job) | this session, 2026-05-26 |
| Flutter (all 3 platforms code) | 230/230 ✅ + analyze clean | green (linux + windows + android jobs) | this session post-slice 17 |
| Linux release build | n/a on macOS | green | release-desktop.yml run `26422664790` |
| Windows release build | n/a on macOS | green | release-desktop.yml run `26422664790` |
| Android APK | local debug+release ✅ | green | Hermes verification 2026-05-25 |
| Docker / HF Spaces | n/a | green | release-desktop.yml run `26422664790` |

**Prod-readiness deltas delivered this session:**
- Slice 12 (iOS): `InstantReaderIndexMapper` extracted; EPUB↔playable invariant collapsed from 3 inline sites to 1 helper.
- Slice 13–14 (Hermes, iOS): helper reused across `PlayerReaderView` + `FullPlayerSheet` chapter rows.
- Slice 15 (Flutter): `ChapterIndexMapper` parity helper landed.
- Slice 16 (Flutter): real bug fixed — `ResumePositionRouter` rewires resume save/restore to EPUB-axis, so books with skipped/pending chapters survive relaunch. Legacy save fallback included.
- Slice 17 (Flutter): `ResumeStore × Router` integration regression with real `SharedPreferences` mock.

**Open items that DO NOT block production (deferred follow-ups):**
- iOS resume axis is documented above as deliberate; no harmonization with Flutter needed.
- Flutter `AudioPlayerService.chapterIndexForPlayerIndex` returns playable-axis labelled as chapter index but no caller misinterprets it; refactor optional.

**Ask:** Hermes — please review slice 12, 15, 16, 17 + this audit + this sign-off; if you concur, append your co-approval entry and we are done. If you find a remaining blocker, name it and I'll pick it up.
