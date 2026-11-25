import '../models/ebook_fulltext.dart';

/// One row of the reader's contents list (mirrors the 16e `ReaderTocRow`).
class ReaderTocRow {
  const ReaderTocRow({required this.title, required this.level, required this.chapterIndex});

  final String title;
  final int level;

  /// 0-based index into `EbookFulltext.chapters`; null when the entry has no parsed chapter.
  final int? chapterIndex;

  @override
  bool operator ==(Object other) =>
      other is ReaderTocRow &&
      other.title == title &&
      other.level == level &&
      other.chapterIndex == chapterIndex;

  @override
  int get hashCode => Object.hash(title, level, chapterIndex);

  @override
  String toString() => 'ReaderTocRow($title, $level, $chapterIndex)';
}

/// The book's nav indented by level, or its chapters when it has none (16e ReaderTocFlattener).
List<ReaderTocRow> readerTocRows(EbookFulltext fulltext) {
  if (fulltext.toc.isEmpty) {
    return [
      for (final (offset, chapter) in fulltext.chapters.indexed)
        ReaderTocRow(title: chapter.displayTitle, level: 0, chapterIndex: offset),
    ];
  }
  final chapters = fulltext.chapters.length;
  List<ReaderTocRow> flatten(List<FulltextTocEntry> entries, int level) => [
    for (final entry in entries) ...[
      ReaderTocRow(
        title: entry.title,
        level: level,
        chapterIndex: switch (entry.chapterIndex) {
          final index? when index >= 1 && index <= chapters => index - 1,
          _ => null,
        },
      ),
      ...flatten(entry.children, level + 1),
    ],
  ];
  return flatten(fulltext.toc, 0);
}
