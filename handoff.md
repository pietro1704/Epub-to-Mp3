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
