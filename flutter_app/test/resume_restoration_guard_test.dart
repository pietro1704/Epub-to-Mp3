import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/resume_position_router.dart';
import 'package:flutter_app/services/resume_restoration_guard.dart';

void main() {
  ChapterProgress completed(int index) => ChapterProgress(
        index: index,
        name: 'Ch$index',
        status: 'completed',
        downloadUrl: 'u$index',
      );

  group('ResumeRestorationGuard', () {
    test(
        'when the saved chapter is not yet in the queue, returns null '
        'and does not consume the restore slot', () {
      // User saved a resume at EPUB-4 but the SSE stream has only
      // shipped EPUB-0 so far. Without this guard book_open_screen
      // called the restore on the first batch, the router returned
      // null, and the restore was silently lost — when EPUB-4 later
      // arrived nothing tried again.
      final guard = ResumeRestorationGuard();
      final router = ResumePositionRouter(playableChapters: [completed(0)]);

      expect(guard.targetForSavedValue(4, router), isNull);
      expect(guard.hasRestored, isFalse,
          reason: 'unresolved attempt must NOT mark restore as done');
    });

    test('returns the queue index once the saved chapter lands and marks '
        'the restore as done', () {
      final guard = ResumeRestorationGuard();
      final router = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(2),
        completed(4),
      ]);

      // EPUB-4 maps to playable index 2 in this layout.
      expect(guard.targetForSavedValue(4, router), 2);
      expect(guard.hasRestored, isTrue);
    });

    test('subsequent calls after a successful restore return null '
        '(do not jump the player back if more chapters arrive)', () {
      final guard = ResumeRestorationGuard();
      final router = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(2),
      ]);

      // First successful restore at EPUB-2.
      expect(guard.targetForSavedValue(2, router), 1);

      // Later snapshot brings more chapters. The guard must NOT
      // restore again — the user has potentially started playing
      // from the restored point already.
      final widerRouter = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(2),
        completed(4),
      ]);
      expect(guard.targetForSavedValue(2, widerRouter), isNull);
      expect(guard.targetForSavedValue(4, widerRouter), isNull);
    });

    test('mid-conversion retries finally succeed when the chapter lands', () {
      // Real SSE arrival pattern: chapter list grows by 1 on each
      // tick. The guard should keep returning null until EPUB-3 is in
      // the queue, then fire exactly once.
      final guard = ResumeRestorationGuard();
      var router = ResumePositionRouter(playableChapters: [completed(0)]);

      expect(guard.targetForSavedValue(3, router), isNull);
      router = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(1),
      ]);
      expect(guard.targetForSavedValue(3, router), isNull);
      router = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(1),
        completed(2),
      ]);
      expect(guard.targetForSavedValue(3, router), isNull);
      router = ResumePositionRouter(playableChapters: [
        completed(0),
        completed(1),
        completed(2),
        completed(3),
      ]);
      expect(guard.targetForSavedValue(3, router), 3,
          reason: 'restore must fire when the saved chapter finally lands');
      // And once.
      expect(guard.targetForSavedValue(3, router), isNull);
    });
  });
}
