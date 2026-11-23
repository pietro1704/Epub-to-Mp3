import 'dart:ui' show TextRange;

import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/services/reader/narration_switch_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const position = ReaderListeningPosition(3, 120);

  test('restarts at the same reader position while listening', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: true,
        supportsPositionedStart: true,
      ),
      same(position),
    );
  });

  test('only saves the choice when nothing is playing', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: false,
        supportsPositionedStart: true,
      ),
      isNull,
    );
  });

  test('does not restart without a position or a positioned converter', () {
    expect(
      narrationSwitchRestartPosition(
        position: null,
        playingChapter: null,
        listening: true,
        supportsPositionedStart: true,
      ),
      isNull,
    );
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: true,
        supportsPositionedStart: false,
      ),
      isNull,
    );
  });

  test('restarts from the playing chapter when the reader shows another one', () {
    final restart = narrationSwitchRestartPosition(
      position: position,
      playingChapter: 5,
      listening: true,
      supportsPositionedStart: true,
    );
    expect(restart?.chapterIndex, 5);
    expect(restart?.textOffset, 0);
  });

  test('uses the requested start while the first audio is still preparing', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: null,
        listening: true,
        supportsPositionedStart: true,
      ),
      same(position),
    );
  });

  _liveSentenceTests();
  _estimateTests();

  test('the sentence being read wins over chapter and reader position', () {
    const sentence = ReaderListeningPosition(5, 321);
    expect(
      narrationSwitchRestartPosition(
        sentence: sentence,
        position: position,
        playingChapter: 5,
        listening: true,
        supportsPositionedStart: true,
      ),
      same(sentence),
    );
    expect(
      narrationSwitchRestartPosition(
        sentence: sentence,
        position: position,
        playingChapter: 5,
        listening: false,
        supportsPositionedStart: true,
      ),
      isNull,
      reason: 'nothing playing: only the choice is saved',
    );
  });
}


void _estimateTests() {
  final chapter = FulltextChapter(
    index: 9,
    text: 'One here now. Two comes next. Three follows after. Four ends it.',
  );

  test('estimate picks the sentence at the same fraction of the text', () {
    final start = estimatedSentenceStart(
      chapter: chapter,
      position: 4,
      seconds: 5,
      durationSeconds: 10,
    );
    expect(start?.chapterIndex, 4, reason: 'the book position, not FulltextChapter.index');
    final spoken = String.fromCharCodes(chapter.text.runes.skip(start!.textOffset));
    expect(spoken.startsWith('Three') || spoken.startsWith('Two'), isTrue);
  });

  test('estimate starts at the first sentence at time zero', () {
    final start = estimatedSentenceStart(chapter: chapter,
      position: 4, seconds: 0, durationSeconds: 10);
    expect(start?.textOffset, 0);
  });

  test('estimate is null without a known duration', () {
    expect(estimatedSentenceStart(chapter: chapter,
      position: 4, seconds: 4, durationSeconds: 0), isNull);
    expect(estimatedSentenceStart(chapter: chapter,
      position: 4, seconds: double.nan, durationSeconds: 10), isNull);
  });
}

void _liveSentenceTests() {
  final chapter = FulltextChapter(
    index: 9,
    text: 'First sentence here. Second sentence follows. Third one ends.',
  );

  test('live sentence start snaps the measured word to its sentence start', () {
    final second = chapter.text.indexOf('sentence follows');
    final start = liveSentenceStart(
      chapter: chapter,
      position: 4,
      measured: TextRange(start: second, end: second + 8),
      liveSentenceId: null,
    );
    expect(start?.chapterIndex, 4, reason: 'the book position, not FulltextChapter.index');
    expect(chapter.text.runes.skip(start!.textOffset).take(6), 'Second'.runes);
  });

  test('live sentence start falls back to the live sentence span', () {
    final spans = chapter.splitSentences();
    final second = spans[1];
    final start = liveSentenceStart(
      chapter: chapter,
      position: 4,
      measured: null,
      liveSentenceId: second.id,
    );
    expect(start?.chapterIndex, 4, reason: 'the book position, not FulltextChapter.index');
    expect(start?.textOffset, second.startChar);
    expect(chapter.text.runes.skip(start!.textOffset).take(6), 'Second'.runes);
  });

  test('live sentence start is null without audible text or outside it', () {
    expect(
      liveSentenceStart(chapter: chapter,
      position: 4, measured: null, liveSentenceId: null),
      isNull,
    );
    expect(
      liveSentenceStart(
        chapter: chapter,
      position: 4,
        measured: const TextRange(start: 9999, end: 10000),
        liveSentenceId: null,
      ),
      isNull,
    );
  });
}
