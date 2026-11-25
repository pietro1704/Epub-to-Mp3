import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/views/reader_chapter_content.dart';

// Linux run 2026-11-25 (The Lord of the Rings, "Book One"): the Shire map is
// `<p class="img"><img class="img1 style20">` with `.style20 { height: 95% }` and
// `.img1 { max-width: 100%; max-height: 100% }`. The reader showed the heading
// and an empty page; the 16e shows the map fitted to the page.
void main() {
  testWidgets('an image sized with percentages in the book CSS stays visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    final png = base64Encode(
      File('test/fixtures/reader_image_400x240.png').readAsBytesSync(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: ReaderHtmlChapterContent(
                html:
                    '<h1>Book One</h1><p class="img"><img alt="map" class="img1 style20" src="data:image/png;base64,$png"/></p>',
                css:
                    '.img { margin-top: 2em; text-align: center; }\n'
                    '.img1 { margin: 0; padding: 0; max-width: 100%; max-height: 100%; }\n'
                    '.style20 { height: 95%; }',
                settings: settings,
                bg: Colors.black,
                fg: Colors.white,
                bodyStyle: const TextStyle(fontSize: 18),
                headingStyle: const TextStyle(fontSize: 24),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final image = find.byType(Image);
    expect(image, findsOneWidget);
    final size = tester.getSize(image);
    expect(size.width, greaterThan(100), reason: 'rendered $size');
    expect(size.height, greaterThan(60), reason: 'rendered $size');
    expect(size.width, lessThanOrEqualTo(600));
  });

  test('only percentage heights are dropped from the book CSS', () {
    expect(
      withoutPercentHeights(
        '.a { line-height: 120%; max-height: 100%; height: 95%; min-height: 50% }\n.b { height: 2em }',
      ),
      '.a { line-height: 120%; max-height: 100%;  min-height: 50% }\n.b { height: 2em }',
    );
  });
}
