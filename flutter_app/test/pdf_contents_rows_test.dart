import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/views/reader_toc_rows.dart';
import 'package:flutter_test/flutter_test.dart';

FulltextChapter _chapter(int index, String source) =>
    FulltextChapter(index: index, text: 't', sourcePath: source);

void main() {
  test('maps each contents entry to the page its chapter starts on', () {
    final book = EbookFulltext(
      jobId: 'j',
      bookTitle: 'b',
      chapters: [_chapter(1, 'page-1'), _chapter(2, 'page-14')],
      toc: const [
        FulltextTocEntry(title: 'One', chapterIndex: 1),
        FulltextTocEntry(title: 'Two', chapterIndex: 2, level: 2),
      ],
    );
    expect(pdfContentsRows(book), const [
      PdfContentsRow(title: 'One', level: 0, page: 1),
      PdfContentsRow(title: 'Two', level: 0, page: 14),
    ]);
  });

  test('a PDF without a contents list shows none', () {
    final book = EbookFulltext(
      jobId: 'j',
      bookTitle: 'b',
      chapters: [_chapter(1, 'page-1')],
    );
    expect(pdfContentsRows(book), isEmpty);
  });
}
