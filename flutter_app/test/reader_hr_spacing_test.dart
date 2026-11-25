import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/views/reader_chapter_content.dart';

void main() {
  // Linux run 2026-11-25 (synthetic EPUB): `<hr class="context"/>` with
  // `hr.context { margin: 1.2em 0 }` left about 250 px of blank page under the rule. The 16e
  // keeps the book's 1.2em above and below it.
  for (final css in [null, 'hr.context{margin:1.2em 0}']) {
    testWidgets('a horizontal rule keeps only its own margins (css: $css)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderHtmlChapterContent(
                html: '<p>Above.</p><hr class="context"/><p>Below.</p>',
                css: css,
                settings: settings,
                bg: Colors.white,
                fg: Colors.black,
                bodyStyle: const TextStyle(fontSize: 18),
                headingStyle: const TextStyle(fontSize: 24),
              ),
            ),
          ),
        ),
      );
      final above = tester.getRect(find.textContaining('Above.', findRichText: true));
      final below = tester.getRect(find.textContaining('Below.', findRichText: true));
      // Two paragraph margins (1em each) and the rule's (1.2em each) on 18 px text.
      expect(below.top - above.bottom, lessThan(18 * 5));
    });
  }
}
