import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';

void main() {
  testWidgets(
    'rich pagination retains markup and chrome changes keep the raw offset',
    (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      final height = ValueNotifier(400.0);
      addTearDown(height.dispose);
      final text = List.generate(
        60,
        (i) => 'Paragraph $i with bold words and ação 🐧.',
      ).join('\n');
      final html = List.generate(
        60,
        (i) => '<p>Paragraph $i with <b>bold words</b> and ação 🐧.</p>',
      ).join();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) => SizedBox(
                  width: 600,
                  height: value,
                  child: RichReaderSurface(
                    chapter: FulltextChapter(index: 0, text: text, html: html),
                    settings: settings,
                    background: Colors.white,
                    foreground: Colors.black,
                    bodyStyle: const TextStyle(fontSize: 20),
                    headingStyle: const TextStyle(fontSize: 24),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Html), findsOneWidget);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('rich-reader-viewport')),
          )
          .controller!;
      await tester.tapAt(const Offset(650, 180));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      final offset = scroll.offset;
      height.value = 500;
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      height.value = 400;
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'original typography respects persisted explicit choices and reset',
    () async {
      SharedPreferences.setMockInitialValues({'readerFontSize': 2});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      expect(settings.readerOverrideFontSize, true);
      expect(settings.readerOverrideFontFamily, false);
      await settings.resetReaderTypography();
      expect(settings.readerOverrideFontSize, false);
      await settings.setReaderFontSize(3);
      expect(settings.readerOverrideFontSize, true);
    },
  );
}
