import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/toc_navigation_coordinator.dart';

void main() {
  final sparsePlayable = <ChapterProgress>[
    ChapterProgress(
        index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
    ChapterProgress(
        index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'b'),
    ChapterProgress(
        index: 4, name: 'Ch5', status: 'completed', downloadUrl: 'c'),
  ];

  group('TocNavigationCoordinator', () {
    test(
        'highlightEpubIndex translates the current playable position back '
        'to its EPUB axis for the TOC selection ring', () {
      // Audio plays playable-1 (= EPUB-2). The TOC's chapter list is
      // EPUB-axis, so the highlight must be on EPUB-2's row.
      expect(
        TocNavigationCoordinator.highlightEpubIndex(
          currentPlayableIndex: 1,
          playableChapters: sparsePlayable,
        ),
        2,
      );
    });

    test('highlightEpubIndex falls back to the playable index when '
        'translation is unavailable', () {
      // Out-of-range playable index → fallback returns the input so
      // the TOC ListView at least doesn't crash.
      expect(
        TocNavigationCoordinator.highlightEpubIndex(
          currentPlayableIndex: 99,
          playableChapters: sparsePlayable,
        ),
        99,
      );
    });

    test('targetPlayableIndexForTocTap returns the playable position when '
        'the tapped EPUB chapter has audio', () {
      // User taps EPUB-2 (which is playable). Player must seek to
      // playable-1 — the position of EPUB-2 in the audio queue.
      expect(
        TocNavigationCoordinator.targetPlayableIndexForTocTap(
          tappedEpubIndex: 2,
          playableChapters: sparsePlayable,
        ),
        1,
      );
    });

    test('targetPlayableIndexForTocTap returns null for pending chapters', () {
      // EPUB-1 has no audio (pending). Caller must NOT seek; reader
      // can update its own EPUB cursor independently.
      expect(
        TocNavigationCoordinator.targetPlayableIndexForTocTap(
          tappedEpubIndex: 1,
          playableChapters: sparsePlayable,
        ),
        isNull,
      );
    });

    test('linear book: both directions are identity', () {
      final linear = <ChapterProgress>[
        for (var i = 0; i < 3; i++)
          ChapterProgress(
              index: i,
              name: 'Ch${i + 1}',
              status: 'completed',
              downloadUrl: 'u$i'),
      ];
      for (var i = 0; i < 3; i++) {
        expect(
          TocNavigationCoordinator.highlightEpubIndex(
            currentPlayableIndex: i,
            playableChapters: linear,
          ),
          i,
        );
        expect(
          TocNavigationCoordinator.targetPlayableIndexForTocTap(
            tappedEpubIndex: i,
            playableChapters: linear,
          ),
          i,
        );
      }
    });

    test('empty playable: highlight is the raw value, taps return null', () {
      // Pre-conversion: no audio exists. TOC highlight is just the
      // raw index; taps cannot select an audio position.
      expect(
        TocNavigationCoordinator.highlightEpubIndex(
          currentPlayableIndex: 0,
          playableChapters: const [],
        ),
        0,
      );
      expect(
        TocNavigationCoordinator.targetPlayableIndexForTocTap(
          tappedEpubIndex: 2,
          playableChapters: const [],
        ),
        isNull,
      );
    });
  });
}
