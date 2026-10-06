import '../models/bookmark.dart';
import '../models/job_snapshot.dart';
import 'chapter_index_mapper.dart';

/// Routes the bookmark `chapterIndex` field between
/// `AudioPlayerService`'s playable axis and the EPUB axis that should
/// be persisted. Mirrors `ResumePositionRouter` (slice 16) — the
/// `BookmarkStore` is keyed by `bookId` (stable across re-conversions)
/// but pre-slice-23 `chapterIndex` was the player_index of whatever
/// playable layout the book had when the bookmark was saved. On
/// re-conversion with a different layout the bookmark pointed
/// nowhere. New saves persist the EPUB-axis index; legacy reads stay
/// compatible via a fallback path.
class BookmarkAxisRouter {
  BookmarkAxisRouter({required List<ChapterProgress> playableChapters})
      : _playableChapters = playableChapters,
        _mapper = ChapterIndexMapper(playableChapters);

  final List<ChapterProgress> _playableChapters;
  final ChapterIndexMapper _mapper;

  /// EPUB-axis value to persist for a new bookmark made while the
  /// audio queue is at `playerIndex`. Returns null when no playable
  /// chapters are loaded yet — callers should skip the save.
  int? saveValueForPlayerIndex(int playerIndex) =>
      _mapper.epubIndexForPlayableIndex(playerIndex);

  /// True when `bookmark` covers the current audio position.
  /// Recognises both the modern EPUB-axis encoding and the legacy
  /// playable-axis one (where the saved value collapses to the
  /// player_index because pre-rewire code stored that directly).
  bool matchesCurrentPosition({
    required Bookmark bookmark,
    required int currentPlayerIndex,
  }) {
    if (_playableChapters.isEmpty) {
      return bookmark.chapterIndex == currentPlayerIndex;
    }
    final epubAtCurrent =
        _mapper.epubIndexForPlayableIndex(currentPlayerIndex);
    if (epubAtCurrent != null && bookmark.chapterIndex == epubAtCurrent) {
      return true;
    }
    return bookmark.chapterIndex == currentPlayerIndex;
  }

  /// Translate a stored bookmark `chapterIndex` into the playable
  /// position the player should seek to when the user taps the
  /// bookmark in the list. Tries EPUB-axis first (new format), then
  /// falls back to treating the stored value as a playable position
  /// (legacy). Returns null when neither resolves.
  int? targetPlayerIndexForStoredValue(int storedValue) {
    if (_playableChapters.isEmpty) {
      return storedValue >= 0 ? storedValue : null;
    }
    final viaEpub = _mapper.playableIndexForEpubIndex(storedValue);
    if (viaEpub != null) return viaEpub;
    if (storedValue >= 0 && storedValue < _playableChapters.length) {
      return storedValue;
    }
    return null;
  }
}
