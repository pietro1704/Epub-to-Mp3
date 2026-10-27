import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  testWidgets('actual Material reader pages fit at 24pt, large scale and changed viewport', (tester) async {
    SharedPreferences.setMockInitialValues({'readerFontSize': 3, 'readerLayout': 'paginated'});
    final prefs = await SharedPreferences.getInstance();
    final text = List.generate(650, (index) => 'word$index').join(' ');
    final chapter = FulltextChapter(index: 0, name: 'Heading', text: text, charCount: text.length);
    final key = GlobalKey<State<ReaderView>>();
    Widget scene(double scale, double height) => ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(theme: ThemeData(useMaterial3: true), home: Scaffold(body: Center(
        child: SizedBox(width: 360, height: height, child: MediaQuery(
          data: MediaQueryData(size: Size(360, height), textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 24, bottom: 16)),
          child: ReaderView(key: key, chapter: chapter, spans: chapter.splitSentences()),
        )),
      ))),
    );
    await tester.pumpWidget(scene(1, 560));
    await tester.pump();
    void assertFit() {
      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, lessThanOrEqualTo(0.01),
        reason: 'A paginated viewport must not require vertical scrolling to reveal its last line');
    }
    assertFit();
    // ignore: invalid_use_of_protected_member
    (key.currentState as dynamic).advancePage();
    await tester.pump();
    assertFit();
    await tester.pumpWidget(scene(1.8, 440));
    await tester.pump();
    assertFit();
  });
}
