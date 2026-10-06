import '../models/job_snapshot.dart';
import 'chapter_index_mapper.dart';

/// Bridges the **playable axis** that `AudioPlayerService` tracks with
/// the **EPUB axis** that `TocDrawer` iterates over. The drawer lists
/// `fulltext.chapters` (EPUB-axis), so both its `currentIndex`
/// highlight and its `onJump` callback are inherently EPUB-axis.
///
/// Pre-slice-20 `player_reader_screen` wired its playable-axis
/// `_currentChapterIndex` straight into both — so on sparse books the
/// highlight landed on the wrong row and TOC taps misrouted the
/// player.
class TocNavigationCoordinator {
  /// What EPUB-axis row the TOC should highlight given the current
  /// position in the audio queue.
  ///
  /// Falls back to the raw playable index when there is no
  /// translation (e.g. no playable chapters yet or the index is out
  /// of range) so the ListView at least does not crash on a sparse
  /// list.
  static int highlightEpubIndex({
    required int currentPlayableIndex,
    required List<ChapterProgress> playableChapters,
  }) {
    if (playableChapters.isEmpty) return currentPlayableIndex;
    final mapper = ChapterIndexMapper(playableChapters);
    return mapper.epubIndexForPlayableIndex(currentPlayableIndex) ??
        currentPlayableIndex;
  }

  /// What playable-axis index the player should seek to when the
  /// user taps the given EPUB row in the TOC, or `null` if the
  /// tapped chapter has no audio (pending / skipped).
  ///
  /// Callers should leave the audio position alone in the null
  /// case; a future slice may update a reader-only EPUB cursor for
  /// the silent jump.
  static int? targetPlayableIndexForTocTap({
    required int tappedEpubIndex,
    required List<ChapterProgress> playableChapters,
  }) {
    if (playableChapters.isEmpty) return null;
    return ChapterIndexMapper(playableChapters)
        .playableIndexForEpubIndex(tappedEpubIndex);
  }
}
