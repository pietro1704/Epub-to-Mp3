# Flutter Companion App

Cross-platform (Android + iOS + macOS) companion for the Epub-to-Mp3
backend. Talks to the same FastAPI server documented in the root
`CLAUDE.md` and mirrors the iOS slice 3 feature set: jobs list, settings,
synchronized audio + reader, TOC drawer, offline fulltext cache.

## Quick start

```bash
mise install                  # ensures Flutter 3.41.9 is on PATH
mise run flutter:test         # run unit tests
mise run flutter:analyze      # static analysis
mise run flutter:run          # launch on the connected device
mise run flutter:build-apk    # debug Android APK
```

iOS / macOS additionally need CocoaPods (`brew install cocoapods`)
before `flutter run -d <device>` succeeds. Android needs the Android
SDK + an emulator or USB device.

## Backend URL

Default: `http://localhost:8000`. Configurable in **Settings → Backend
URL**, persisted via `shared_preferences`. For HF Spaces, use the public
Space URL (e.g. `https://<user>-epub-to-mp3.hf.space`).

## Screens

- `lib/screens/jobs_list_screen.dart` — pull-to-refresh sessions list
  (`GET /api/sessions`).
- `lib/screens/settings_screen.dart` — backend URL, WPM, audio rate,
  font size, dark mode.
- `lib/screens/player_reader_screen.dart` — split layout (reader on top,
  player controls on bottom; side-by-side at >700dp).
- `lib/screens/reader_view.dart` — sentence-highlighted text driven by
  `currentSentenceProvider`.
- `lib/screens/toc_drawer.dart` — chapter list with jump-to-chapter.

## Architecture

- **State**: Riverpod 2 (`lib/state/providers.dart`).
- **Models**: freezed + json_serializable (`lib/models/`). Wire format
  matches iOS — `JobSnapshot` and `EbookFulltext` use camelCase;
  `SessionRecord` uses snake_case.
- **Services** (`lib/services/`):
  - `api_client.dart` — dio wrapper, SSE parser, fulltext error mapping
    (503 → `FulltextTransient`, 404 → `FulltextGone`, 422 →
    `FulltextEmpty`).
  - `fulltext_store.dart` — retry ladder `[800, 1500, 3000, 6000,
    12000]ms` with on-disk cache.
  - `sync_engine.dart` — pure Dart port of iOS `SyncEngine.swift`.
  - `audio_player_service.dart` — just_audio `ConcatenatingAudioSource`.
  - `download_manager.dart` — dio download with persisted queue.
  - `resume_store.dart` — shared_preferences-based per-chapter resume.

## i18n

ARB files live in `lib/l10n/` (`app_en.arb`, `app_pt.arb`). Generated
delegate is created on `flutter pub get` (set via `l10n.yaml` +
`generate: true` in `pubspec.yaml`). Mirror keys exist in both locales.

## Tests

```bash
mise run flutter:test
```

Coverage:
- `test/models_roundtrip_test.dart` — JSON decoding for all models.
- `test/sync_engine_test.dart` — timing distribution + WPM fallback +
  segment walk + empty chapter.
- `test/resume_store_test.dart` — save/load round-trip.
