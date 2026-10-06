import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import 'reader_chapter_resolver.dart';
import 'sync_engine.dart';

/// Drives a `SyncEngine` from a `(fulltext, playableChapters,
/// playableIndex)` triple + a position stream so the Flutter reader
/// gets the sentence-level highlight feature parity with iOS.
///
/// Pre-slice-24 `syncEngineProvider` was created but nothing ever
/// called `engine.load(...)` or `engine.update(...)`. The Flutter
/// reader silently shipped without highlight sync. iOS has driven
/// this from `InstantReaderView.installPositionLoop` since v0.3.x.
class SentenceSyncCoordinator {
  SentenceSyncCoordinator(SyncEngine engine) : _engine = engine;

  SyncEngine _engine;
  SyncEngine get engine => _engine;

  EbookFulltext? _lastFulltext;
  int _lastPlayableIndex = -1;

  /// Re-point the coordinator at a fresh `SyncEngine` instance and
  /// clear the load memo. `syncEngineProvider` rebuilds the engine
  /// whenever its watched dependencies (e.g. `settings.wpm`) change;
  /// without this rebind the cached coordinator kept driving the
  /// disposed engine while `currentSentenceProvider` listened to the
  /// new one — sentence highlight silently stopped updating.
  ///
  /// No-op when `newEngine` is the same instance as the current one.
  void rebindIfEngineChanged(SyncEngine newEngine) {
    if (identical(_engine, newEngine)) return;
    _engine = newEngine;
    _lastFulltext = null;
    _lastPlayableIndex = -1;
  }

  /// Re-load the engine when either the fulltext payload or the
  /// playable cursor changes. Idempotent on identical inputs.
  void loadIfChanged({
    required EbookFulltext fulltext,
    required List<ChapterProgress> playableChapters,
    required int playableIndex,
  }) {
    if (identical(fulltext, _lastFulltext) &&
        playableIndex == _lastPlayableIndex) {
      return;
    }
    final chapter = ReaderChapterResolver.resolveFulltextChapter(
      fulltext: fulltext,
      playableChapters: playableChapters,
      playableIndex: playableIndex,
    );
    if (chapter == null) return;
    _lastFulltext = fulltext;
    _lastPlayableIndex = playableIndex;
    final duration = _durationForChapter(playableChapters, chapter.index);
    _engine.load(chapter, duration);
  }

  /// Forward an audio position tick (seconds) to the engine. Returns
  /// the resolved sentence id, if any.
  String? updatePosition(double positionSeconds) =>
      _engine.update(positionSeconds);

  double _durationForChapter(
      List<ChapterProgress> playableChapters, int epubIndex) {
    for (final c in playableChapters) {
      if (c.index == epubIndex) return c.durationSeconds ?? 0.0;
    }
    return 0.0;
  }
}
