import '../models/job_snapshot.dart';
import 'chapter_index_mapper.dart';

/// Routes resume-position saves and restores between the
/// `AudioPlayerService` player axis and the EPUB chapter axis stored
/// in `ResumeStore`.
///
/// Without this, `book_open_screen` was saving a player_index dressed
/// as a chapter index and restoring it by matching `c.index` directly
/// — that round-trip only worked for linear books (no skipped /
/// pending chapters). For sparse layouts the saved value pointed to
/// nowhere and the user lost their listening position on app relaunch.
class ResumePositionRouter {
  ResumePositionRouter({required List<ChapterProgress> playableChapters})
      : _playableChapters = playableChapters,
        _mapper = ChapterIndexMapper(playableChapters);

  final List<ChapterProgress> _playableChapters;
  final ChapterIndexMapper _mapper;

  /// Translates the *current* player index (an index into the queue
  /// passed to `setQueue`) into the EPUB-axis value we want to persist
  /// in `ResumeStore`. Returns null when the player index is out of
  /// range — caller should skip the save in that case.
  int? saveValueForPlayerIndex(int playerIndex) =>
      _mapper.epubIndexForPlayableIndex(playerIndex);

  /// Translates a stored save value back into a queue index suitable
  /// for `player.seek(..., index: queueIndex)`. Tries the EPUB-axis
  /// interpretation first (new format) and falls back to treating the
  /// stored value as a playable-axis position (legacy format from
  /// before this slice). Returns null when neither resolves — caller
  /// should skip the restore.
  int? queueIndexForSavedValue(int savedValue) {
    final viaEpub = _mapper.playableIndexForEpubIndex(savedValue);
    if (viaEpub != null) return viaEpub;
    if (savedValue >= 0 && savedValue < _playableChapters.length) {
      return savedValue;
    }
    return null;
  }
}
