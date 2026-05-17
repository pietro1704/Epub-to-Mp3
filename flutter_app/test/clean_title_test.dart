import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';

void main() {
  group('FulltextChapter.cleanTitle', () {
    test('inserts space before uppercase run glued to lowercase', () {
      expect(FulltextChapter.cleanTitle('parteI'), 'Parte I');
      expect(FulltextChapter.cleanTitle('capítuloIII'), 'Capítulo III');
    });

    test('inserts space before digits glued to letters', () {
      expect(FulltextChapter.cleanTitle('Chapter3'), 'Chapter 3');
    });

    test('capitalizes each word', () {
      expect(FulltextChapter.cleanTitle('a tale of two cities'),
          'A Tale Of Two Cities');
    });

    test('uppercases roman numeral tokens', () {
      expect(FulltextChapter.cleanTitle('Part ii'), 'Part II');
      expect(FulltextChapter.cleanTitle('chapter xiv'), 'Chapter XIV');
      expect(FulltextChapter.cleanTitle('book xx'), 'Book XX');
    });

    test('handles already-clean titles', () {
      expect(FulltextChapter.cleanTitle('Chapter 1'), 'Chapter 1');
      expect(FulltextChapter.cleanTitle('Prologue'), 'Prologue');
    });

    test('trims whitespace', () {
      expect(FulltextChapter.cleanTitle('  hello  '), 'Hello');
    });

    test('handles mixed case with roman numerals', () {
      expect(FulltextChapter.cleanTitle('PART III'), 'Part III');
    });
  });

  group('FulltextChapter.displayTitle', () {
    test('uses cleanTitle when name is non-empty', () {
      const ch = FulltextChapter(
        index: 1,
        name: 'parteII',
        text: 'Some text',
      );
      expect(ch.displayTitle, 'Parte II');
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
    test('uses cleanTitle when name is non-empty', () {
      const cp = ChapterProgress(
        index: 0,
        name: 'capítuloV',
      );
      expect(cp.displayTitle, 'Capítulo V');
    });

    test('falls back to Chapter N+1 when name is null', () {
      const cp = ChapterProgress(
        index: 2,
      );
      expect(cp.displayTitle, 'Chapter 3');
    });
  });
}
