import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';

void main() {
  // Linux run 2026-11-25: the TOC showed "Competente O Suficiente" for the book's
  // "Competente o Suficiente". Like iOS (title fidelity), the book's own title is shown as is.
  group('chapter titles keep the book casing', () {
    test('a TOC title is shown as the book writes it', () {
      const ch = FulltextChapter(index: 0, name: ' Competente o Suficiente ', text: '');
      expect(ch.displayTitle, 'Competente o Suficiente');
      const cp = ChapterProgress(index: 0, name: 'Como ler este livro');
      expect(cp.displayTitle, 'Como ler este livro');
    });
  });

  group('FulltextChapter.displayTitle', () {
    test('uses the name as the book writes it when non-empty', () {
      const ch = FulltextChapter(
        index: 1,
        name: 'parteII',
        text: 'Some text',
      );
      expect(ch.displayTitle, 'parteII');
    });

    test('falls back to Chapter N when name is null', () {
      const ch = FulltextChapter(
        index: 3,
        text: 'Some text',
      );
      expect(ch.displayTitle, 'Chapter 3');
    });

    test('falls back to Chapter N when name is empty', () {
      const ch = FulltextChapter(
        index: 5,
        name: '',
        text: 'Some text',
      );
      expect(ch.displayTitle, 'Chapter 5');
    });
  });

  group('ChapterProgress.displayTitle', () {
    test('uses the name as the book writes it when non-empty', () {
      const cp = ChapterProgress(
        index: 0,
        name: 'capítuloV',
      );
      expect(cp.displayTitle, 'capítuloV');
    });

    test('falls back to Chapter N+1 when name is null', () {
      const cp = ChapterProgress(
        index: 2,
      );
      expect(cp.displayTitle, 'Chapter 3');
    });
  });
}
