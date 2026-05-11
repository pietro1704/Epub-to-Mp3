# SwiftUI → Flutter Mirror Map

**Source of truth:** SwiftUI app at `ios/EpubToMp3/EpubToMp3/`. This
table tracks which Dart files in `flutter_app/lib/` are mirrors of
which Swift files, and when each was last synced.

When the SwiftUI side changes:

1. The PostToolUse hook `.claude/hooks/flutter_mirror_after_swift.sh`
   appends the changed Swift file to `.claude/mirror-queue.txt`.
2. Run `/agents flutter-mirror` (or invoke from a Stop hook) to drain
   the queue — the agent reads each Swift file, mirrors the behaviour
   to its Dart counterpart, updates the SHA column below, and commits.
3. Tests on both sides keep parity-critical logic pinned.

What's mirrored:
- State machines, callback contracts, JSON/wire shape
- Test names (Swift `testFoo` ↔ Dart `test('foo', ...)`)

What's NOT mirrored (each platform stays idiomatic):
- Pixel/animation/gesture details
- Apple-only APIs (`MPNowPlayingInfoCenter`, `URLSessionWebSocketTask`)
- Platform-specific embed code (PythonKit ↔ Chaquopy ↔ subprocess)

## Views

| SwiftUI                                      | Dart counterpart                                | Last synced SHA | Status |
|----------------------------------------------|-------------------------------------------------|-----------------|--------|
| `Views/BookOpenView.swift`                   | `lib/views/book_open_view.dart`                 | —               | TODO   |
| `Views/ConvertView.swift`                    | `lib/views/convert_view.dart`                   | —               | TODO   |
| `Views/InstantReaderView.swift`              | `lib/views/instant_reader_view.dart`            | —               | TODO   |
| `Views/JobDetailView.swift`                  | `lib/views/job_detail_view.dart`                | —               | TODO   |
| `Views/JobsListView.swift`                   | `lib/views/jobs_list_view.dart`                 | —               | TODO   |
| `Views/LibraryView.swift`                    | `lib/views/library_view.dart`                   | —               | TODO   |
| `Views/LocalEpubReaderView.swift`            | `lib/views/local_epub_reader_view.dart`         | —               | TODO   |
| `Views/LogsView.swift`                       | `lib/views/logs_view.dart`                      | —               | TODO   |
| `Views/PlayerReaderView.swift`               | `lib/views/player_reader_view.dart`             | —               | TODO   |
| `Views/ReaderView.swift`                     | `lib/views/reader_view.dart`                    | —               | TODO   |
| `Views/RootView.swift`                       | `lib/views/root_view.dart`                      | —               | TODO   |
| `Views/SettingsView.swift`                   | `lib/views/settings_view.dart`                  | —               | TODO   |
| `Views/TelemetryView.swift`                  | `lib/views/telemetry_view.dart`                 | —               | TODO   |
| `Views/PlatformCompat.swift`                 | n/a (use `Theme.of(context)` / `Platform`)      | —               | n/a    |
| `Views/PreviewFixtures.swift`                | n/a (Flutter has its own test fixtures)         | —               | n/a    |

## Services (behaviour + state machines)

| SwiftUI                                      | Dart counterpart                                | Last synced SHA | Status |
|----------------------------------------------|-------------------------------------------------|-----------------|--------|
| `Services/Paginator.swift`                   | `lib/services/paginator.dart`                   | —               | TODO   |
| `Services/AudioPlayer.swift`                 | `lib/services/audio_player.dart`                | —               | TODO   |
| `Services/SyncEngine.swift`                  | `lib/services/sync_engine.dart`                 | —               | TODO   |
| `Services/DownloadManager.swift`             | `lib/services/download_manager.dart`            | —               | TODO   |
| `Services/FulltextStore.swift`               | `lib/services/fulltext_store.dart`              | —               | TODO   |
| `Services/LibraryStore.swift`                | `lib/services/library_store.dart`               | —               | TODO   |
| `Services/LocalFulltextCache.swift`          | `lib/services/local_fulltext_cache.dart`        | —               | TODO   |
| `Services/ResumeStore.swift`                 | `lib/services/resume_store.dart`                | —               | TODO   |
| `Services/PythonBridge.swift`                | `lib/services/python_bridge.dart`               | ad9939b         | synced |
| `Services/EdgeTTSBridge.swift`               | n/a (Android/Desktop call edge_tts Python direct) | —             | n/a    |
| `Services/PythonEmbed.swift`                 | n/a (PythonKit only)                            | —               | n/a    |
| `Services/SidecarManager.swift`              | n/a (Tauri-only path was deleted)               | —               | n/a    |
| `Services/EpubMetadataReader.swift`          | n/a (parsing lives in python_app)               | —               | n/a    |
| `Services/ZipReader.swift`                   | n/a (parsing lives in python_app)               | —               | n/a    |
| `Services/APIClient.swift`                   | `lib/services/api_client.dart` (if remote mode) | —               | TODO   |

## Models (wire shape)

| SwiftUI                                      | Dart counterpart                                | Last synced SHA | Status |
|----------------------------------------------|-------------------------------------------------|-----------------|--------|
| `Models/AppSettings.swift`                   | `lib/models/app_settings.dart`                  | —               | TODO   |
| `Models/BookEntity.swift`                    | `lib/models/book_entity.dart`                   | —               | TODO   |
| `Models/EbookFulltext.swift`                 | `lib/models/ebook_fulltext.dart` (freezed)      | —               | synced |
| `Models/JobSnapshot.swift`                   | `lib/models/job_snapshot.dart` (freezed)        | —               | synced |
| `Models/SessionRecord.swift`                 | `lib/models/session_record.dart` (freezed)      | —               | synced |

Last full sweep: 2026-05-11 (initial map; SHA column empty for files
not yet mirrored).
