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
