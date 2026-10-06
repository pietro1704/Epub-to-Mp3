import '../models/job_snapshot.dart';

/// Translates between the **EPUB chapter axis** (sparse, zero-based,
/// includes pending + skipped chapters) and the **playable axis**
/// (filtered, dense — only chapters with `downloadUrl`).
///
/// Mirrors the iOS `InstantReaderIndexMapper` so both clients pin the
/// same invariant: a chapter tap or position-sync update must be
/// translated through this helper, never indexed directly.
class ChapterIndexMapper {
  ChapterIndexMapper(List<ChapterProgress> allChapters)
      : _playableEpubIndices = [
          for (final c in allChapters)
            if (c.downloadUrl != null) c.index,
        ];

  final List<int> _playableEpubIndices;

  /// Forward map: EPUB-axis index → playable-axis index, or null if
  /// the EPUB chapter has no audio (pending/skipped).
  int? playableIndexForEpubIndex(int epubIndex) {
    final i = _playableEpubIndices.indexOf(epubIndex);
    return i >= 0 ? i : null;
  }

  /// Reverse map: playable-axis index → EPUB-axis index, or null if
  /// out of bounds.
  int? epubIndexForPlayableIndex(int playableIndex) {
    if (playableIndex < 0 || playableIndex >= _playableEpubIndices.length) {
      return null;
    }
    return _playableEpubIndices[playableIndex];
  }
}
