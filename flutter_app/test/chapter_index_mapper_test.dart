import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/chapter_index_mapper.dart';

void main() {
  group('ChapterIndexMapper (sparse playable layout)', () {
    final chapters = <ChapterProgress>[
      ChapterProgress(
          index: 0, name: 'Ch1', status: 'completed', downloadUrl: 'a'),
      ChapterProgress(index: 1, name: 'Ch2', status: 'pending'),
      ChapterProgress(
          index: 2, name: 'Ch3', status: 'completed', downloadUrl: 'b'),
      ChapterProgress(index: 3, name: 'Ch4', status: 'skipped'),
      ChapterProgress(
          index: 4, name: 'Ch5', status: 'completed', downloadUrl: 'c'),
    ];

    final mapper = ChapterIndexMapper(chapters);

    test('forward: EPUB index → playable index', () {
      expect(mapper.playableIndexForEpubIndex(0), 0);
      expect(mapper.playableIndexForEpubIndex(2), 1);
      expect(mapper.playableIndexForEpubIndex(4), 2);
      expect(mapper.playableIndexForEpubIndex(1), isNull,
          reason: 'pending chapter has no playable position');
      expect(mapper.playableIndexForEpubIndex(3), isNull,
          reason: 'skipped chapter has no playable position');
    });

    test('reverse: playable index → EPUB index', () {
      expect(mapper.epubIndexForPlayableIndex(0), 0);
      expect(mapper.epubIndexForPlayableIndex(1), 2);
      expect(mapper.epubIndexForPlayableIndex(2), 4);
      expect(mapper.epubIndexForPlayableIndex(3), isNull,
          reason: 'out of bounds');
      expect(mapper.epubIndexForPlayableIndex(-1), isNull);
    });

    test('round-trip is stable on playable EPUB indices', () {
      for (final epub in [0, 2, 4]) {
        final playable = mapper.playableIndexForEpubIndex(epub);
        expect(playable, isNotNull);
        expect(mapper.epubIndexForPlayableIndex(playable!), epub);
      }
    });
  });
}
