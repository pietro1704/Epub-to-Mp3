import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Linux run 2026-11-25 (The Lord of the Rings, "Book One", window 1400x420): the Shire
// map was cut at the bottom of the page. The 16e caps an image taller than a page to the
// usable page height (ReaderInlineImageLayout), keeping its aspect ratio.
void main() {
  testWidgets('a paginated image taller than the page fits the page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    final png = base64Encode(
      File('test/fixtures/reader_image_400x900.png').readAsBytesSync(),
    );
    const surfaceHeight = 360.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 600,
              height: surfaceHeight,
              child: RichReaderSurface(
                chapter: FulltextChapter(
                  index: 0,
                  text: 'Map',
                  html:
                      '<p>Map</p><p><img alt="" src="data:image/png;base64,$png"/></p>',
                ),
                settings: settings,
                background: Colors.white,
                foreground: Colors.black,
                bodyStyle: const TextStyle(fontSize: 16, height: 1.5),
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
    final size = tester.getSize(find.byType(Image));
    expect(size.height, greaterThan(100), reason: 'rendered $size');
    expect(
      size.height,
      lessThanOrEqualTo(surfaceHeight - 28 - 32),
      reason: 'rendered $size',
    );
    expect(
      size.width / size.height,
      closeTo(400 / 900, 0.02),
      reason: 'rendered $size',
    );
  });
}
