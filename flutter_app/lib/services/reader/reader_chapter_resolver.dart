import '../../models/ebook_fulltext.dart';
import '../../models/job_snapshot.dart';
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
/// and then takes the fulltext chapter at that place in the book. The audio
/// queue names chapters by their position in `fulltext.chapters`; the parser's
/// `FulltextChapter.index` is a different identity (1-based for Rust-parsed
/// books, and not even numeric for nested tables of contents), so it is never
/// compared with the queue. When
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

    return epubIndex >= 0 && epubIndex < chapters.length
        ? chapters[epubIndex]
        : null;
  }
}
