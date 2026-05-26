import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/resume_position_router.dart';

void main() {
  group('ResumePositionRouter', () {
    final sparseChapters = <ChapterProgress>[
      ChapterProgress(
          index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
      ChapterProgress(index: 1, name: 'Ch2', status: 'pending'),
      ChapterProgress(
          index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'b'),
      ChapterProgress(index: 3, name: 'Ch4', status: 'skipped'),
      ChapterProgress(
          index: 4, name: 'Ch5', status: 'completed', downloadUrl: 'c'),
    ];

    // Most books in the wild — no skipped chapters.
    final linearChapters = <ChapterProgress>[
      ChapterProgress(
          index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
      ChapterProgress(
          index: 1, name: 'Ch2', status: 'completed', downloadUrl: 'b'),
      ChapterProgress(
          index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'c'),
    ];

    test('save: player index 2 in sparse layout serialises EPUB index 4', () {
      final router = ResumePositionRouter(playableChapters: sparseChapters);

      expect(router.saveValueForPlayerIndex(2), 4);
      expect(router.saveValueForPlayerIndex(0), 0);
      expect(router.saveValueForPlayerIndex(1), 2);
    });

    test('restore: EPUB index 4 resolves to playable index 2 (sparse)', () {
      final router = ResumePositionRouter(playableChapters: sparseChapters);

      expect(router.queueIndexForSavedValue(4), 2);
      expect(router.queueIndexForSavedValue(2), 1);
      expect(router.queueIndexForSavedValue(0), 0);
    });

    test('restore: legacy saves in playable-position format still resume', () {
      // Pre-slice saves recorded the player_index dressed as a chapter
      // index. For a sparse book, that value can land in a position that
      // does not exist as `c.index`. The router must fall back to treating
      // a small integer as a playable-axis position so users do not lose
      // their resume point on the first launch after the upgrade.
      final router = ResumePositionRouter(playableChapters: sparseChapters);

      // Legacy save: user listened to playable-index 2 (EPUB-4) but the
      // old code stored it as `2`. The new EPUB-axis lookup matches
      // playable-index 1 (EPUB-2) — that is the intended legacy fallback
      // for stored playable-axis values that incidentally land on an
      // existing EPUB-axis index. Subsequent saves overwrite with the
      // new format.
      expect(router.queueIndexForSavedValue(2), 1);

      // Legacy save that lands on a non-existent EPUB index (chapter 1
      // is pending). Falls back to playable-position interpretation.
      expect(router.queueIndexForSavedValue(1), 1,
          reason: 'no chapter has c.index == 1; restore must reuse stored '
              'value as a playable position');
    });

    test('restore: out-of-range save returns null', () {
      final router = ResumePositionRouter(playableChapters: sparseChapters);

      expect(router.queueIndexForSavedValue(99), isNull);
      expect(router.queueIndexForSavedValue(-1), isNull);
    });

    test('linear book: save and restore are stable identity', () {
      final router = ResumePositionRouter(playableChapters: linearChapters);

      for (var i = 0; i < linearChapters.length; i++) {
        final saved = router.saveValueForPlayerIndex(i);
        expect(saved, linearChapters[i].index);
        expect(router.queueIndexForSavedValue(saved!), i);
      }
    });
  });
}
