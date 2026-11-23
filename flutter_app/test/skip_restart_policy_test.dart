import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/reader/narration_switch_policy.dart';
import 'package:flutter_test/flutter_test.dart';

String _book() => List.generate(40, (i) => 'Frase número ${i + 1} do capítulo, com algum texto para falar em voz alta.').join(' ');

String _spoken(FulltextChapter chapter, int sourceOffset) =>
    String.fromCharCodes(chapter.text.runes.skip(sourceOffset));

void main() {
  final chapter = FulltextChapter(index: 3, text: _book());

  test('forward skip outside the audio restarts at the sentence the voice speed predicts', () {
    // 30 s at 15 scalars/s ~ 450 scalars into the chapter.
    final restart = skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 0, targetSeconds: 30);
    expect(restart, isNotNull);
    expect(restart!.chapterIndex, 2, reason: 'the book position, not FulltextChapter.index');
    expect(_spoken(chapter, restart.textOffset), startsWith('Frase número'));
    expect(restart.textOffset, inInclusiveRange(380, 450), reason: 'the sentence that starts at or before 450');
  });

  test('the job start shifts the estimate (a restarted job begins mid-chapter)', () {
    final fromStart = skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 0, targetSeconds: 10)!;
    final fromMiddle = skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 600, targetSeconds: 10)!;
    expect(fromMiddle.textOffset, greaterThan(fromStart.textOffset + 400));
  });

  test('backward skip lands earlier in the text and never before the chapter start', () {
    final back = skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 900, targetSeconds: 0)!;
    expect(back.textOffset, lessThanOrEqualTo(900));
    final clamped = skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 0, targetSeconds: -5)!;
    expect(clamped.textOffset, 0);
  });

  test('a target beyond the chapter text is left to the next-chapter logic', () {
    expect(skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 0, targetSeconds: 100000), isNull);
  });

  test('unusable input gives no restart', () {
    expect(skipRestartPosition(chapter: chapter, position: 2, startSourceOffset: 0, targetSeconds: double.nan), isNull);
    expect(skipRestartPosition(chapter: FulltextChapter(index: 0, text: ''), position: 0, startSourceOffset: 0, targetSeconds: 5), isNull);
  });
}
