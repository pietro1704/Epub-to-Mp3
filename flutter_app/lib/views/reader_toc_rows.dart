import '../models/ebook_fulltext.dart';

/// One row of the reader's contents list (mirrors the 16e `ReaderTocRow`).
class ReaderTocRow {
  const ReaderTocRow({
    required this.title,
    required this.level,
    required this.chapterIndex,
    this.anchorOffset,
  });

  final String title;
  final int level;

  /// 0-based index into `EbookFulltext.chapters`; null when the entry has no parsed chapter.
  final int? chapterIndex;

  /// Scalar offset inside that chapter's text where the entry's fragment sits; null jumps to the chapter start.
  final int? anchorOffset;

  @override
  bool operator ==(Object other) =>
      other is ReaderTocRow &&
      other.title == title &&
      other.level == level &&
      other.chapterIndex == chapterIndex &&
      other.anchorOffset == anchorOffset;

  @override
  int get hashCode => Object.hash(title, level, chapterIndex, anchorOffset);

  @override
  String toString() =>
      'ReaderTocRow($title, $level, $chapterIndex, $anchorOffset)';
}

/// The book's nav indented by level, or its chapters when it has none (16e ReaderTocFlattener).
///
/// [names] holds the reader's chapter name overrides keyed by chapter index; they rename the
/// rows that open a chapter (a row pointing inside a chapter keeps the book's own title).
List<ReaderTocRow> readerTocRows(
  EbookFulltext fulltext, {
  Map<int, String> names = const {},
}) {
  if (fulltext.toc.isEmpty) {
    return [
      for (final (offset, chapter) in fulltext.chapters.indexed)
        ReaderTocRow(
          title: names[chapter.index] ?? chapter.displayTitle,
          level: 0,
          chapterIndex: offset,
        ),
    ];
  }
  final chapters = fulltext.chapters.length;
  List<ReaderTocRow> flatten(List<FulltextTocEntry> entries, int level) => [
    for (final entry in entries) ...[
      () {
        final index = switch (entry.chapterIndex) {
          final index? when index >= 1 && index <= chapters => index - 1,
          _ => null,
        };
        final fragment = entry.fragment;
        final renamed = index == null || fragment != null
            ? null
            : names[fulltext.chapters[index].index];
        return ReaderTocRow(
          title: renamed ?? entry.title,
          level: level,
          chapterIndex: index,
          anchorOffset: index == null || fragment == null
              ? null
              : fulltext.chapters[index].anchors?[fragment],
        );
      }(),
      ...flatten(entry.children, level + 1),
    ],
  ];
  return flatten(fulltext.toc, 0);
}
