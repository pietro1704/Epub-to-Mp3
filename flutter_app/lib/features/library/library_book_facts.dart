import '../../models/book_entity.dart';
import '../../models/ebook_fulltext.dart';
import '../../services/conversion/local_conversion_record.dart';

enum LibraryAudioState { notConverted, partial, complete }

/// What a library card says about a book, derived only from data the app already keeps:
/// the library entry, the cached text, the latest local conversion job and the resume position.
class LibraryBookFacts {
  const LibraryBookFacts({
    required this.format,
    required this.isPdf,
    this.chapterCount,
    this.resumeChapter,
    this.audioState = LibraryAudioState.notConverted,
    this.audioDone = 0,
    this.audioTotal = 0,
    this.date,
    this.dateIsLastRead = false,
  });

  /// `PDF` or `EPUB`.
  final String format;
  final bool isPdf;

  /// Chapters of an EPUB; for a PDF without an outline each chapter is one page.
  final int? chapterCount;

  /// 1-based chapter the reader last stopped in.
  final int? resumeChapter;
  final LibraryAudioState audioState;
  final int audioDone;
  final int audioTotal;
  final DateTime? date;
  final bool dateIsLastRead;

  /// Share of chapters finished before the current one, 0-100.
  int? get progressPercent {
    final total = chapterCount;
    final current = resumeChapter;
    if (total == null || total <= 0 || current == null) return null;
    return (((current - 1) * 100) / total).round().clamp(0, 100);
  }

  static LibraryBookFacts of(
    BookEntity book, {
    EbookFulltext? fulltext,
    LocalConversionJob? job,
    ({int chapter, double seconds})? resume,
  }) {
    final isPdf = book.filePath.toLowerCase().endsWith('.pdf');
    final chapters = job?.chapters ?? const <LocalConversionChapter>[];
    final done = chapters.where((c) => c.status == 'completed').length;
    final state = chapters.isEmpty || done == 0
        ? LibraryAudioState.notConverted
        : done == chapters.length
        ? LibraryAudioState.complete
        : LibraryAudioState.partial;
    final lastRead = book.lastPlayedAt ?? book.lastOpenedAt;
    return LibraryBookFacts(
      format: isPdf ? 'PDF' : 'EPUB',
      isPdf: isPdf,
      chapterCount: fulltext?.chapters.length,
      resumeChapter: resume == null ? null : resume.chapter + 1,
      audioState: state,
      audioDone: done,
      audioTotal: chapters.length,
      date: lastRead ?? book.addedAt,
      dateIsLastRead: lastRead != null,
    );
  }
}
