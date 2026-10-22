import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/views/reader_chapter_content.dart';

void main() {
  for (final alignment in ReaderTextAlignment.values) {
    final expectedAlignment = alignment == ReaderTextAlignment.left
        ? TextAlign.left
        : TextAlign.justify;

    testWidgets('HTML content accepts model settings: ${alignment.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'readerTextAlignment': alignment.rawValue,
      });
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderHtmlChapterContent(
              html: '<p>HTML body</p>',
              settings: settings,
              bg: Colors.white,
              fg: Colors.black,
              bodyStyle: const TextStyle(fontSize: 18),
              headingStyle: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      );

      final html = tester.widget<Html>(find.byType(Html));
      expect(html.style['p']?.textAlign, expectedAlignment);
      expect(tester.takeException(), isNull);
    });

    testWidgets('span content preserves settings and tap identity: ${alignment.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'readerTextAlignment': alignment.rawValue,
      });
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      const span = SentenceSpan(
        id: 'chapter-2-sentence-1',
        text: 'Span body',
        startChar: 0,
        endChar: 9,
      );
      SentenceSpan? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSpanChapterContent(
              spans: const [span],
              settings: settings,
              fg: Colors.black,
              bodyStyle: const TextStyle(fontSize: 18),
              header: const Text('Chapter 2'),
              activeId: span.id,
              spanKeys: <String, GlobalKey>{},
              onJumpToSentence: (value) => selected = value,
            ),
          ),
        ),
      );

      expect(tester.widget<Text>(find.text(span.text)).textAlign, expectedAlignment);
      await tester.tap(find.text(span.text));
      expect(selected, same(span));
      expect(tester.takeException(), isNull);
    });
  }
}
