import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/views/reader_toc_rows.dart';
import 'package:flutter_test/flutter_test.dart';

// Linux reader 2026-11-25 (synthetic EPUB): the contents list showed every parsed chapter,
// including a title page the nav leaves out, and lost the nesting. Mirrors the 16e
// ReaderTocFlattener: nav rows indented by level, chapters only without a nav.
void main() {
  Map<String, dynamic> chapter(int index, String name) => {'index': index, 'name': name, 'text': 'Body.'};

  test('the book nav becomes indented rows pointing at 0-based chapters', () {
    final fulltext = EbookFulltext.fromJson({
      'jobId': 'job',
      'chapters': [chapter(1, 'Test Book'), chapter(2, 'Part One'), chapter(3, 'Chapter Two')],
      'toc': [
        {
          'title': 'Part One',
          'level': 1,
          'chapterIndex': 2,
          'children': [
            {'title': 'Chapter Two', 'level': 2, 'chapterIndex': 3, 'children': []},
            {'title': 'Lost', 'level': 2, 'chapterIndex': null, 'children': []},
          ],
        },
      ],
    });
    expect(readerTocRows(fulltext), const [
      ReaderTocRow(title: 'Part One', level: 0, chapterIndex: 1),
      ReaderTocRow(title: 'Chapter Two', level: 1, chapterIndex: 2),
      ReaderTocRow(title: 'Lost', level: 1, chapterIndex: null),
    ]);
  });

  test('a book without a nav lists its chapters', () {
    final fulltext = EbookFulltext.fromJson({
      'jobId': 'job',
      'chapters': [chapter(1, 'One'), chapter(2, 'Two')],
    });
    expect(readerTocRows(fulltext), const [
      ReaderTocRow(title: 'One', level: 0, chapterIndex: 0),
      ReaderTocRow(title: 'Two', level: 0, chapterIndex: 1),
    ]);
  });

  // Anchor-bearing entries (#1666 FFI `fragment`, chapter `anchors`): tapping must land on the
  // anchor, not the chapter start; unknown fragments fall back to the chapter start.
  test('a nav fragment resolves to its anchor offset inside the chapter', () {
    final fulltext = EbookFulltext.fromJson({
      'jobId': 'job',
      'chapters': [
        {...chapter(1, 'One'), 'anchors': {'mid': 23}},
      ],
      'toc': [
        {'title': 'One', 'level': 1, 'chapterIndex': 1, 'children': []},
        {'title': 'Middle', 'level': 1, 'chapterIndex': 1, 'fragment': 'mid', 'children': []},
        {'title': 'Gone', 'level': 1, 'chapterIndex': 1, 'fragment': 'nope', 'children': []},
      ],
    });
    expect(readerTocRows(fulltext).map((row) => row.anchorOffset), [null, 23, null]);
  });
}
