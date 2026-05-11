// Mirror of ios/EpubToMp3/EpubToMp3Tests/ReaderChapterAdvanceTests.swift @ 1f20d54
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// Regression: paginated reader used to dead-end on the last page of
// the current chapter. Fix delegates to the host view's
// advance/retreat callbacks at the page boundary. These tests
// exercise the host-side counters that those callbacks bump
// (`ChapterAdvanceModel`) without mounting a widget tree.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  test('advance moves forward through chapters', () {
    final m = ChapterAdvanceModel(currentChapterIndex: 0, chapterCount: 5);
    expect(m.advance(), isTrue);
    expect(m.currentChapterIndex, 1);
    expect(m.advance(), isTrue);
    expect(m.advance(), isTrue);
    expect(m.advance(), isTrue);
    expect(m.currentChapterIndex, 4);
  });

  test('advance returns false on last chapter', () {
    final m = ChapterAdvanceModel(currentChapterIndex: 4, chapterCount: 5);
    expect(
      m.advance(),
      isFalse,
      reason:
          'must report no-advance on the last chapter so the reader stays put',
    );
    expect(m.currentChapterIndex, 4);
  });

  test('retreat moves backward', () {
    final m = ChapterAdvanceModel(currentChapterIndex: 3, chapterCount: 5);
    expect(m.retreat(), isTrue);
    expect(m.currentChapterIndex, 2);
  });

  test('retreat returns false on first chapter', () {
    final m = ChapterAdvanceModel(currentChapterIndex: 0, chapterCount: 5);
    expect(m.retreat(), isFalse);
    expect(m.currentChapterIndex, 0);
  });

  test('Carl scenario: 24 chapters stay reachable end-to-end', () {
    // Pale Blue Dot has ~24 chapters. Simulate the user paging
    // through to the end and back to confirm no dead-end.
    final m = ChapterAdvanceModel(currentChapterIndex: 0, chapterCount: 24);
    var advanced = 0;
    while (m.advance()) {
      advanced++;
    }
    expect(advanced, 23);
    expect(m.currentChapterIndex, 23);

    var retreated = 0;
    while (m.retreat()) {
      retreated++;
    }
    expect(retreated, 23);
    expect(m.currentChapterIndex, 0);
  });

  test('single-chapter book has no advance target', () {
    // Defensive: a 1-chapter book should report no-advance and
    // no-retreat, so the reader silently keeps the page bound.
    final m = ChapterAdvanceModel(currentChapterIndex: 0, chapterCount: 1);
    expect(m.advance(), isFalse);
    expect(m.retreat(), isFalse);
  });
}
