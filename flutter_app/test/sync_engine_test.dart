import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('estimateTiming distributes duration proportional to char count', () {
    final engine = SyncEngine(wpm: 200);
    final spans = const [
      SentenceSpan(id: 'a', text: 'aaaa', startChar: 0, endChar: 4), // 4
      SentenceSpan(id: 'b', text: 'bbbbbbbb', startChar: 5, endChar: 13), // 8
    ];
    final timing = engine.estimateTiming(spans, 12.0);
    expect(timing.length, 2);
    expect(timing.first.startMs, 0);
    // 4/12 = 1/3 of 12000 ms = 4000.
    expect((timing.first.endMs - 4000).abs() <= 1, true);
    expect(timing.last.endMs, 12000);
  });

  test('WPM fallback when duration unknown', () {
    final engine = SyncEngine(wpm: 200);
    final spans = const [
      SentenceSpan(id: 'a', text: 'word word word word word', startChar: 0, endChar: 24),
    ];
    final timing = engine.estimateTiming(spans, 0);
    expect(timing.length, 1);
    expect(timing.first.endMs > 0, true);
  });

  test('load + update walks segments and emits sentence ids', () async {
    final chapter = FulltextChapter(
      index: 0,
      text: 'One sentence. Two sentence! Three.',
    );
    final engine = SyncEngine(wpm: 200);
    engine.load(chapter, 6.0); // 6s total split between 3 spans
    final ids = <String?>[];
    final sub = engine.currentSentence.listen(ids.add);

    engine.update(0.5); // first sentence
    engine.update(3.0); // middle
    engine.update(5.5); // last
    engine.update(7.0); // beyond -> nil

    await Future.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    engine.dispose();

    expect(ids.contains('0:0'), true);
    expect(ids.last, null);
  });

  test('empty chapter -> empty timing', () {
    final engine = SyncEngine();
    engine.load(const FulltextChapter(index: 0, text: ''), 5.0);
    expect(engine.timing, isEmpty);
    expect(engine.source, TimingSource.empty);
  });
}
