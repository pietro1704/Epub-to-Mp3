import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/sentence_sync_coordinator.dart';
import 'package:flutter_app/services/sync_engine.dart';

void main() {
  final fulltext = EbookFulltext(
    jobId: 'j',
    bookTitle: 'Sparse Book',
    bookAuthor: null,
    chapters: [
      FulltextChapter(index: 0, name: 'Ch1', text: 'First chapter. Sentence two.'),
      FulltextChapter(index: 1, name: 'Ch2', text: 'pending placeholder'),
      FulltextChapter(index: 2, name: 'Ch3', text: 'Third chapter. Another sentence.'),
    ],
  );

  final sparsePlayable = <ChapterProgress>[
    ChapterProgress(
        index: 0,
        name: 'Ch1',
        status: 'completed',
        downloadUrl: 'a',
        durationSeconds: 12.0),
    ChapterProgress(
        index: 2,
        name: 'Ch3',
        status: 'completed',
        downloadUrl: 'b',
        durationSeconds: 18.0),
  ];

  group('SentenceSyncCoordinator', () {
    test('loadIfChanged loads the EPUB chapter that matches the playable '
        'position (sparse layout)', () {
      final engine = SyncEngine();
      final coordinator = SentenceSyncCoordinator(engine);

      // Audio at playable-1 (EPUB-2). Reader text + sync table must
      // come from FulltextChapter(index: 2), not chapters[1] which is
      // the pending placeholder.
      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 1,
      );

      expect(engine.spans, isNotEmpty,
          reason: 'engine should have loaded sentence spans');
      // First sentence of EPUB-2 is "Third chapter."
      expect(engine.spans.first.text.startsWith('Third chapter'), isTrue,
          reason: 'wrong chapter loaded; reader would highlight EPUB-1 text');
    });

    test('loadIfChanged is a no-op when neither fulltext nor index changed',
        () {
      final engine = SyncEngine();
      final coordinator = SentenceSyncCoordinator(engine);

      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 0,
      );
      final firstSpans = engine.spans;

      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 0,
      );
      // Same instance — re-load would reset state needlessly.
      expect(engine.spans, same(firstSpans),
          reason: 'second call with same inputs must skip engine.load');
    });

    test('loadIfChanged reloads when the playable index changes', () {
      final engine = SyncEngine();
      final coordinator = SentenceSyncCoordinator(engine);

      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 0,
      );
      expect(engine.spans.first.text.startsWith('First chapter'), isTrue);

      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 1,
      );
      expect(engine.spans.first.text.startsWith('Third chapter'), isTrue,
          reason: 'switching to playable-1 should re-load EPUB-2');
    });

    test('updatePosition passes seconds through to the engine', () {
      final engine = SyncEngine();
      final coordinator = SentenceSyncCoordinator(engine);

      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 0,
      );

      final sentenceId = coordinator.updatePosition(0.5);
      // At t=0.5s the first sentence should be active.
      expect(sentenceId, isNotNull,
          reason: 'engine should resolve a sentence id at t=0.5');
    });

    test('loadIfChanged skips when the chapter cannot be resolved', () {
      final engine = SyncEngine();
      final coordinator = SentenceSyncCoordinator(engine);

      // Out-of-range playable index → resolver returns null → no load.
      coordinator.loadIfChanged(
        fulltext: fulltext,
        playableChapters: sparsePlayable,
        playableIndex: 99,
      );
      expect(engine.spans, isEmpty);
    });
  });
}
