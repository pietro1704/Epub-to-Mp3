import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/bookmark.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/bookmark_axis_router.dart';

void main() {
  final sparsePlayable = <ChapterProgress>[
    ChapterProgress(
        index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
    ChapterProgress(
        index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'b'),
    ChapterProgress(
        index: 4, name: 'Ch5', status: 'completed', downloadUrl: 'c'),
  ];

  Bookmark legacy(int chapterIndex) => Bookmark(
        id: 'legacy-$chapterIndex',
        bookId: 'book-uuid',
        chapterIndex: chapterIndex,
        chapterTitle: 'Ch$chapterIndex',
        createdAt: DateTime(2025, 1, 1),
      );

  Bookmark modern(int epubIndex) => Bookmark(
        id: 'modern-$epubIndex',
        bookId: 'book-uuid',
        chapterIndex: epubIndex,
        chapterTitle: 'Ch$epubIndex',
        createdAt: DateTime(2026, 1, 1),
      );

  group('BookmarkAxisRouter', () {
    test('saveValueForPlayerIndex serialises EPUB axis on sparse layout', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Audio plays playable-1 (EPUB-2). New bookmarks must persist 2.
      expect(router.saveValueForPlayerIndex(1), 2);
      expect(router.saveValueForPlayerIndex(0), 0);
      expect(router.saveValueForPlayerIndex(2), 4);
    });

    test('matchesCurrentPosition accepts modern EPUB-axis bookmark', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Bookmark recorded for EPUB-2 (modern format) matches audio at
      // playable-1.
      expect(
        router.matchesCurrentPosition(
          bookmark: modern(2),
          currentPlayerIndex: 1,
        ),
        isTrue,
      );
    });

    test(
        'matchesCurrentPosition accepts legacy playable-axis bookmark '
        'whose stored value happens to equal the player index', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Pre-slice-23 saves recorded the player_index. Audio is at
      // playable-2 (EPUB-4). Legacy bookmark with chapterIndex=2 must
      // still match so users do not lose existing markers.
      expect(
        router.matchesCurrentPosition(
          bookmark: legacy(2),
          currentPlayerIndex: 2,
        ),
        isTrue,
      );
    });

    test(
        'matchesCurrentPosition rejects unrelated stored values that '
        'land on neither axis', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Audio at playable-1 (EPUB-2). A bookmark with chapterIndex=7
      // matches neither axis → no match.
      expect(
        router.matchesCurrentPosition(
          bookmark: Bookmark(
            id: 'wrong',
            bookId: 'book-uuid',
            chapterIndex: 7,
            chapterTitle: 'Junk',
            createdAt: DateTime(2026),
          ),
          currentPlayerIndex: 1,
        ),
        isFalse,
      );
    });

    test('targetPlayerIndexForStoredValue translates EPUB back to playable',
        () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Bookmarks list tap: stored value 2 (EPUB-2) → seek to playable-1.
      expect(router.targetPlayerIndexForStoredValue(2), 1);
      expect(router.targetPlayerIndexForStoredValue(0), 0);
      expect(router.targetPlayerIndexForStoredValue(4), 2);
    });

    test('targetPlayerIndexForStoredValue legacy fallback', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Legacy save recorded playable-index 2 (EPUB-4). The new code
      // tries EPUB-axis first (no chapter with .index == 2 in the
      // legacy sense → returns playable-1 actually, because EPUB-2
      // exists). The router prefers the EPUB interpretation; legacy
      // values that incidentally collide with a real EPUB index are
      // accepted as such — that is the cost of not migrating data.
      // This test pins the documented trade-off so a future change
      // cannot silently switch the preference.
      expect(router.targetPlayerIndexForStoredValue(2), 1,
          reason: 'EPUB interpretation wins when both axes match');
    });

    test('targetPlayerIndexForStoredValue legacy fallback for non-existent '
        'EPUB index falls back to playable axis', () {
      final router = BookmarkAxisRouter(playableChapters: sparsePlayable);

      // Stored value 1 has no playable EPUB chapter (chapter 1 is
      // pending in our sparse layout). Fall back to treating 1 as a
      // playable index → returns 1 directly.
      expect(router.targetPlayerIndexForStoredValue(1), 1);
    });

    test('linear book: forward + reverse are identity', () {
      final linear = <ChapterProgress>[
        for (var i = 0; i < 3; i++)
          ChapterProgress(
              index: i,
              name: 'Ch${i + 1}',
              status: 'completed',
              downloadUrl: 'u$i'),
      ];
      final router = BookmarkAxisRouter(playableChapters: linear);
      for (var i = 0; i < 3; i++) {
        expect(router.saveValueForPlayerIndex(i), i);
        expect(router.targetPlayerIndexForStoredValue(i), i);
      }
    });

    test('empty playable: save returns null, query falls back to playable axis',
        () {
      final router = BookmarkAxisRouter(playableChapters: const []);
      expect(router.saveValueForPlayerIndex(0), isNull);
      expect(
        router.matchesCurrentPosition(
          bookmark: legacy(2),
          currentPlayerIndex: 2,
        ),
        isTrue,
        reason:
            'empty playable → only the legacy playable-axis path applies',
      );
    });
  });
}
