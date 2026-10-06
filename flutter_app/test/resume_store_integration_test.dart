import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/resume_position_router.dart';
import 'package:flutter_app/services/resume_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('ResumeStore × ResumePositionRouter wire-shape regression', () {
    test(
        'new save persists EPUB axis and restore round-trips to the original '
        'player position', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ResumeStore(prefs);
      final router =
          ResumePositionRouter(playableChapters: sparseChapters);

      // User listened to playable position 2 (the third audible
      // chapter — EPUB-4).
      const userPlayableIdx = 2;
      const userPosition = 184.5;

      final epubIdx = router.saveValueForPlayerIndex(userPlayableIdx);
      expect(epubIdx, 4,
          reason: 'rewire must persist EPUB-axis, not player-axis');

      await store.saveBookPosition('book-uuid', epubIdx!, userPosition);

      // Verify the on-disk shape is just the EPUB-axis int + the
      // position double — no schema change vs the pre-rewire wire
      // format. ResumeStore is a tiny shim over SharedPreferences;
      // breaking the shape would cause a silent skip on next launch.
      expect(prefs.getInt('resume:book:book-uuid:chapter'), 4);
      expect(prefs.getDouble('resume:book:book-uuid:position'), userPosition);

      // Relaunch: load, route, and confirm we land where we left off.
      final saved = store.loadBookPosition('book-uuid');
      expect(saved, isNotNull);
      expect(router.queueIndexForSavedValue(saved!.chapter), userPlayableIdx);
      expect(saved.seconds, userPosition);
    });

    test(
        'legacy save (player-axis int from pre-rewire code) restores via '
        'router fallback', () async {
      // Emulate a save written by the pre-rewire `_startResumeListener`
      // that recorded `chapterIndexForPlayerIndex(playerIdx)` which
      // collapsed to the player_index because every caller pre-filters
      // chapters before `setQueue`. For player position 2 in a sparse
      // book the legacy value on disk is therefore `2`, not `4`.
      SharedPreferences.setMockInitialValues({
        'resume:book:book-uuid:chapter': 1,
        'resume:book:book-uuid:position': 12.0,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ResumeStore(prefs);
      final router =
          ResumePositionRouter(playableChapters: sparseChapters);

      final saved = store.loadBookPosition('book-uuid');
      expect(saved, isNotNull);
      // EPUB-1 does not exist in the playable layout (pending). The
      // router must fall back to treating the saved int as a
      // playable-axis position so the user does not lose their resume
      // point on the first launch after the upgrade.
      expect(router.queueIndexForSavedValue(saved!.chapter), 1,
          reason: 'fallback path keeps legacy saves functional');
    });

    test('legacy save out of range is rejected (no crash, no restore)',
        () async {
      SharedPreferences.setMockInitialValues({
        'resume:book:book-uuid:chapter': 99,
        'resume:book:book-uuid:position': 1.0,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ResumeStore(prefs);
      final router =
          ResumePositionRouter(playableChapters: sparseChapters);

      final saved = store.loadBookPosition('book-uuid');
      expect(saved, isNotNull);
      expect(router.queueIndexForSavedValue(saved!.chapter), isNull,
          reason: 'router must return null so the seek is skipped');
    });

    test('missing save returns null without touching the router', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ResumeStore(prefs);

      expect(store.loadBookPosition('book-uuid'), isNull);
    });
  });
}
