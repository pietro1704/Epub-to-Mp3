import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  testWidgets('page navigation publishes the visible raw source anchor without starting audio', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final prefs = await SharedPreferences.getInstance();
    final source = List.generate(90, (index) => 'Sentence $index contains á🙂 selected source words.').join(' ');
    final chapter = FulltextChapter(index: 0, text: source);
    final key = GlobalKey<State<ReaderView>>();
    final offsets = <int?>[];
    await tester.pumpWidget(ProviderScope(overrides:[sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(home: Scaffold(body: SizedBox(width: 360, height: 480,
        child: ReaderView(key: key, chapter: chapter, spans: chapter.splitSentences(), onVisibleTextOffset: offsets.add))))));
    await tester.pump();
    expect(offsets.last, 0);
    // ignore: invalid_use_of_protected_member
    (key.currentState as dynamic).advancePage();
    await tester.pump();
    expect(offsets.last, greaterThan(0));
    final anchor = offsets.last!;
    final visible = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? '').where((text) => text.contains('selected source words')).first;
    expect(String.fromCharCodes(source.runes.skip(ReaderListeningPosition.fromDisplayScalar(0, source, anchor).textOffset)).startsWith(visible.trim()), isTrue);
    expect(tester.takeException(), isNull);
  });
}
