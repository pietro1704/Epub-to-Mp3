import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import 'chapter_index_mapper.dart';

/// Picks the right `FulltextChapter` to render in the reader pane
/// given a player position on the **playable axis**.
///
/// Pre-slice-19 `_Reader` was doing `fulltext.chapters[currentChapterIndex]`,
/// which treats the playable-axis cursor as if it indexed the
/// fulltext list directly. That works for linear books but on books
/// with pending or skipped chapters it shows the wrong chapter text
/// — e.g. audio plays EPUB-2 while the reader renders EPUB-1.
///
/// This resolver translates playable → EPUB via `ChapterIndexMapper`
/// and then looks up the fulltext entry whose `.index` matches. When
/// `playableChapters` is empty (typically before audio exists) it
/// falls back to direct indexing so the user can still read the
/// book.
class ReaderChapterResolver {
  static FulltextChapter? resolveFulltextChapter({
    required EbookFulltext fulltext,
    required List<ChapterProgress> playableChapters,
    required int playableIndex,
  }) {
    final chapters = fulltext.chapters;
    if (chapters.isEmpty) return null;

    if (playableChapters.isEmpty) {
      if (playableIndex < 0 || playableIndex >= chapters.length) return null;
      return chapters[playableIndex];
    }

    final mapper = ChapterIndexMapper(playableChapters);
    final epubIndex = mapper.epubIndexForPlayableIndex(playableIndex);
    if (epubIndex == null) return null;

    for (final c in chapters) {
      if (c.index == epubIndex) return c;
    }
    return null;
  }
}
