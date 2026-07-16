# iOS → Android Feature Parity Plan

> Scope: implement Android/Flutter equivalents for user-facing iOS capabilities that are genuinely absent, without duplicating existing Flutter features.

## Baseline

- Android/Flutter: `flutter analyze` passed; `flutter test` passed with 295 tests.
- Android already has: library import for EPUB/PDF, metadata/cover model, reader, pagination/scroll, reader chrome, TOC, search, bookmarks, settings, mini/full player, resume position, sentence sync, downloads/cache, SSE, sync engine, embedded Chaquopy Python/TTS conversion, EPUB/PDF MIME intents.
- Repository state: `master` is 10 commits ahead of `origin/master`, with additional uncommitted iOS/widget changes. Preserve and review all existing work before final commit/push.

## Candidate gaps to confirm and implement

### P0 — Android playback surface parity

- Android media notification / lock-screen controls / background playback equivalent to iOS Now Playing, WidgetKit controls, and App Intents.
- Native lifecycle and audio focus handling.
- Files: `flutter_app/lib/services/audio_player_service.dart`, `flutter_app/pubspec.yaml`, `flutter_app/android/app/src/main/AndroidManifest.xml`, native Android integration as required.
- Tests: playback state mapping, play/pause/seek/next/previous command routing, notification metadata, background lifecycle.

### P1 — Android home-screen/widget parity

- Android home-screen widget or an explicitly documented equivalent for current-book metadata and playback controls.
- Verify whether a widget plugin already exists before adding one; do not invent a second App Group-like persistence path.
- Files likely: `pubspec.yaml`, `android/`, shared payload service under `lib/services/`.
- Tests: payload serialization, stale/missing metadata fallback, command round-trip.

### P1 — PDF reader parity

- Confirm whether Flutter currently renders PDFs or only imports/stores them.
- If absent, add a supported Android/Flutter PDF reader path with page navigation, search/metadata behavior, and chrome toggle.
- Keep EPUB reader behavior unchanged.
- Tests: open PDF fixture, page navigation, chrome, missing/corrupt file.

### P1 — Conversion status/watchdog parity

- Confirm whether Android exposes iOS conversion status sheet, watchdog timeout/retry/cancel, and progress metadata.
- Implement missing state transitions using existing `DownloadManager`, SSE, and Python bridge rather than a parallel state model.
- Tests: progress, completed, failed, timeout, retry, cancel, stale job guard.

### P2 — TTS/voice fallback parity

- Confirm current Android support for voice selection, Edge fallback, Piper fallback, language detection, and playable output validation.
- Implement only missing user-visible controls/fallbacks; keep Chaquopy as the Android engine where it already works.
- Tests: voice list, fallback ordering, language detection, invalid output/retry.

### P2 — Cloud/persistence parity

- Confirm whether iOS CloudKit sync has a legitimate Android backend/equivalent. Do not assume CloudKit can be used directly on Android.
- If absent, implement backend-backed sync through the existing `SyncEngine`/API contract, or document as non-portable if no server contract exists.
- Tests: bookmark/resume/settings conflict and offline reconciliation.

### P2 — Import/deep-link edge cases

- Confirm Android handles content URIs, persisted URI permissions, `ACTION_SEND`, and app relaunch import—not only filesystem paths.
- Implement URI-to-cache copy and deduplication if missing.
- Tests: content URI, file URI, share intent, relaunch, duplicate import.

## Gates

1. Inventory specialist reports reconcile this document with actual code.
2. Each confirmed gap gets a failing test before implementation.
3. Run `flutter analyze`, `flutter test`, Android debug/release build, and relevant device/UI automation.
4. Run iOS focused tests/build to ensure parity work does not regress existing iOS changes.
5. Review diff and generated files; exclude build artifacts and local properties.
6. Commit in focused commits, then push `master` to `origin` only after all gates pass.

---

## Confirmed inventory from specialist audit

### Already present in Flutter/Android

Library import/deduplication/metadata/covers/tags/search/sort; EPUB parsing; fulltext cache; paginated and scroll reader; themes/font/margins/spacing/alignment; TOC/search/bookmarks/resume; mini/full player; playlist/seek/speed/sleep timer; backend upload/SSE; local Chaquopy Edge-TTS conversion; downloads/cache eviction; sync/resolver services.

### Confirmed missing or materially incomplete

1. Dedicated manual conversion screen with engine/voice/language/chapter range/cache/reprocess/performance controls.
2. Root navigation parity for Jobs, job details, logs, telemetry, and adaptive split/sidebar layouts.
3. Global runtime warm-up/progress/retry surface.
4. Android `ACTION_VIEW`/`ACTION_SEND` consumption; manifest filters exist but `MainActivity` does not process or forward them.
5. Durable copying of Android `content://` documents into private storage.
6. Visual PDF reader; current Android path imports/parses PDF text but has no PDF page viewer.
7. EPUB fallback parser/rendering parity for malformed files, images, links, embedded fonts and richer CSS behavior.
8. Full-book continuous scroll parity in the local reader.
9. Background audio, MediaSession, lock-screen/media notification, audio focus/noisy handling and process recovery.
10. Persistent local conversion jobs with retry/cancel/watchdog/background execution.
11. Android offline `TextToSpeech` fallback when Edge-TTS/audio is unavailable.
12. Android home-screen widgets for Now Playing/Continue Reading/library, plus widget deep links.
13. Conversion progress notification equivalent to iOS Live Activity.
14. App shortcuts/deep links for open book/player/continue reading.
15. Manual cache cleanup and complete offline badge refresh.
16. Advanced reader/audio position reconciliation and divergence choice UI.
17. Android build validation with a real SDK/device; current host lacks Android SDK.

### Not direct gaps

- iCloud/CloudKit: iOS implementation is a scaffold and UI says coming soon.
- Security-scoped bookmarks: replace with durable Android URI copying, not a literal port.
- AirPlay: use Android MediaRouter/Bluetooth semantics if required, not an iOS API clone.
- Page-curl/TextKit/UIKit internals: implement equivalent Flutter behavior, not the same internals.

### Execution order

F1 intents/URI persistence → F2 PDF reader and local-reader parity → F3 background audio/MediaSession → F4 persistent conversion jobs → F5 TTS fallback → F6 conversion notification/widgets/deep links → F7 Jobs/logs/telemetry/manual conversion UI → final Android SDK/device validation.
