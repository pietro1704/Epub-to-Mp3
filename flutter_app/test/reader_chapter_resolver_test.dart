import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/reader_chapter_resolver.dart';

void main() {
  group('ReaderChapterResolver (sparse playable layout)', () {
    final playableChapters = <ChapterProgress>[
      ChapterProgress(
          index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
      ChapterProgress(
          index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'b'),
      ChapterProgress(
          index: 4, name: 'Ch5', status: 'completed', downloadUrl: 'c'),
    ];

    // Fulltext keeps EPUB-axis indices for ALL chapters (the pending
    // ones are skipped from playable but still have parsed text). The
    // resolver must match by `.index`, not by list position.
    final fulltext = EbookFulltext(
      jobId: 'j',
      bookTitle: 'Sparse Book',
      bookAuthor: null,
      chapters: [
        FulltextChapter(index: 0, name: 'Ch1', text: 'one'),
        FulltextChapter(index: 1, name: 'Ch2', text: 'two-pending'),
        FulltextChapter(index: 2, name: 'Ch3', text: 'three'),
        FulltextChapter(index: 3, name: 'Ch4', text: 'four-skipped'),
        FulltextChapter(index: 4, name: 'Ch5', text: 'five'),
      ],
    );

    test('playable index 1 resolves to the EPUB-2 chapter text', () {
      final ch = ReaderChapterResolver.resolveFulltextChapter(
        fulltext: fulltext,
        playableChapters: playableChapters,
        playableIndex: 1,
      );
      expect(ch?.text, 'three',
          reason: 'audio at playable-1 plays EPUB-2; reader must follow');
    });

    test('playable index 0 resolves to EPUB-0', () {
      final ch = ReaderChapterResolver.resolveFulltextChapter(
        fulltext: fulltext,
        playableChapters: playableChapters,
        playableIndex: 0,
      );
      expect(ch?.text, 'one');
    });

    test('playable index 2 resolves to EPUB-4 (skips both pending+skipped)',
        () {
      final ch = ReaderChapterResolver.resolveFulltextChapter(
        fulltext: fulltext,
        playableChapters: playableChapters,
        playableIndex: 2,
      );
      expect(ch?.text, 'five');
    });

    test('out-of-range playable index returns null', () {
      final ch = ReaderChapterResolver.resolveFulltextChapter(
        fulltext: fulltext,
        playableChapters: playableChapters,
        playableIndex: 99,
      );
      expect(ch, isNull);
    });

    test('linear playable (no gaps) round-trips identity', () {
      final linearPlayable = <ChapterProgress>[
        for (var i = 0; i < 3; i++)
          ChapterProgress(
              index: i,
              name: 'Ch${i + 1}',
              status: 'completed',
              downloadUrl: 'u$i'),
      ];
      final linearFulltext = EbookFulltext(
        jobId: 'j',
        bookTitle: 'Linear',
        bookAuthor: null,
        chapters: [
          for (var i = 0; i < 3; i++)
            FulltextChapter(index: i, name: 'Ch${i + 1}', text: 't$i'),
        ],
      );
      for (var i = 0; i < 3; i++) {
        final ch = ReaderChapterResolver.resolveFulltextChapter(
          fulltext: linearFulltext,
          playableChapters: linearPlayable,
          playableIndex: i,
        );
        expect(ch?.text, 't$i');
      }
    });

    test(
        'empty playable falls back to indexing fulltext directly so the '
        'reader still renders before audio exists', () {
      // Pre-conversion: the user opened a book whose audio has not
      // been generated yet. The reader must still display chapters
      // even though `playableChapters` is empty.
      final ch = ReaderChapterResolver.resolveFulltextChapter(
        fulltext: fulltext,
        playableChapters: const [],
        playableIndex: 2,
      );
      expect(ch?.text, 'three',
          reason: 'fallback should treat playable index as fulltext position');
    });
  });
}
