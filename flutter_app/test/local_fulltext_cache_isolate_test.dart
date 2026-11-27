import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/services/storage/local_fulltext_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reading a large cached book does not stall the UI isolate', () async {
    final dir = await Directory.systemTemp.createTemp('fulltext_cache_stall');
    addTearDown(() => dir.delete(recursive: true));
    // About 38 MB: parsing it on the calling isolate froze the event loop for ~300 ms.
    final chapters = [
      for (var i = 0; i < 4000; i++)
        {
          'index': i,
          'name': 'C$i',
          'text': 'Sentence one. ' * 600,
          'anchors': {for (var a = 0; a < 100; a++) 'id$a': a},
        },
    ];
    await File('${dir.path}/book1.json').writeAsString(
      jsonEncode({'jobId': 'j', 'chapters': chapters, 'readerContentVersion': 2}),
    );

    final clock = Stopwatch()..start();
    final ticks = <int>[clock.elapsedMilliseconds];
    final ticker = Timer.periodic(
      const Duration(milliseconds: 2),
      (_) => ticks.add(clock.elapsedMilliseconds),
    );
    final fulltext = await LocalFulltextCache(
      directoryProvider: () async => dir,
    ).read('book1');
    ticks.add(clock.elapsedMilliseconds);
    ticker.cancel();
    var worstGapMs = 0;
    for (var i = 1; i < ticks.length; i++) {
      final gap = ticks[i] - ticks[i - 1];
      if (gap > worstGapMs) worstGapMs = gap;
    }

    expect(fulltext?.chapters.length, 4000);
    expect(worstGapMs, lessThan(120), reason: 'event loop stalled $worstGapMs ms');
  });
}
