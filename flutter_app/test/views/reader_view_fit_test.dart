import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  testWidgets(
    'actual Material reader pages fit at 24pt, large scale and changed viewport',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerFontSize': 3,
        'readerLayout': 'paginated',
      });
      final prefs = await SharedPreferences.getInstance();
      final text = List.generate(650, (index) => 'word$index').join(' ');
      final chapter = FulltextChapter(
        index: 0,
        name: 'Heading',
        text: text,
        charCount: text.length,
      );
      final key = GlobalKey<State<ReaderView>>();
      final anchors = <int?>[];
      var reachedEnd = false;
      Widget scene(double scale, double height) => ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: height,
                child: MediaQuery(
                  data: MediaQueryData(
                    size: Size(360, height),
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(top: 24, bottom: 16),
                  ),
                  child: ReaderView(
                    key: key,
                    chapter: chapter,
                    spans: chapter.splitSentences(),
                    onVisibleTextOffset: anchors.add,
                    onAdvanceChapter: () {
                      reachedEnd = true;
                      return true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(scene(1, 560));
      await tester.pump();
      void assertFit() {
        expect(tester.takeException(), isNull);
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(
          scrollable.position.maxScrollExtent,
          lessThanOrEqualTo(0.01),
          reason:
              'A paginated viewport must not require vertical scrolling to reveal its last line',
        );
      }

      assertFit();
      // ignore: invalid_use_of_protected_member
      (key.currentState as dynamic).advancePage();
      await tester.pump();
      assertFit();
      final anchor = anchors.last!;
      await tester.pumpWidget(scene(1.8, 440));
      await tester.pump();
      assertFit();
      final anchoredText = String.fromCharCodes(
        text.runes.skip(anchor).take(12),
      );
      expect(find.textContaining(anchoredText), findsOneWidget);
      final footer = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .firstWhere((t) => RegExp(r'^\d+ / \d+$').hasMatch(t));
      final pageCount = int.parse(footer.split(' / ').last);
      for (var turn = 0; turn <= pageCount && !reachedEnd; turn++) {
        // ignore: invalid_use_of_protected_member
        (key.currentState as dynamic).advancePage();
        await tester.pump();
        assertFit();
      }
      expect(reachedEnd, isTrue);
      expect(find.textContaining('word649'), findsOneWidget);
      await tester.pumpWidget(scene(3, 80));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('word0', findRichText: true),
        findsWidgets,
        reason:
            'An impossible paginated viewport must retain the source in a scrolling fallback',
      );
      expect(
        anchors.last,
        0,
        reason:
            'Fallback reports the current source, never the retired final page',
      );
      await tester.pumpWidget(scene(1, 560));
      await tester.pump();
      assertFit();
      expect(
        anchors.last,
        0,
        reason: 'Leaving fallback preserves its visible source anchor',
      );
    },
  );
}
