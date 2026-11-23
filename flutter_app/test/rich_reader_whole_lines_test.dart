// Pietro: with the bars visible no text line may show cut at the top or the bottom of
// a page; a page shows only whole lines. The test renders every page of the rich
// reader and looks at the pixels: each line of ink must have its full height.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<List<int>> _inkRows(WidgetTester tester, GlobalKey boundary) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => render.toImage()))!;
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final width = image.width;
  final rows = <int>[];
  for (var y = 0; y < image.height; y++) {
    var ink = false;
    for (var x = 0; x < width && !ink; x += 2) {
      final i = (y * width + x) * 4;
      // White background; any dark pixel is ink.
      if (data.getUint8(i) < 128) ink = true;
    }
    if (ink) rows.add(y);
  }
  return rows;
}

/// Heights of the runs of consecutive ink rows (one per text line).
List<int> _lineHeights(List<int> rows) {
  final heights = <int>[];
  var run = 0;
  for (var i = 0; i < rows.length; i++) {
    run++;
    if (i == rows.length - 1 || rows[i + 1] != rows[i] + 1) {
      heights.add(run);
      run = 0;
    }
  }
  return heights;
}

void main() {
  _fractionalViewport();
  for (final surfaceHeight in [
    333.0,
    347.0,
    359.0,
    361.0,
    372.0,
    389.0,
    401.0,
    417.0,
    590.0,
  ]) {
    const lineHeight = 1.6;
    testWidgets(
      'every page shows whole lines only (surface height $surfaceHeight)',
      (tester) async {
        SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
        final settings = MirrorAppSettings(
          await SharedPreferences.getInstance(),
        );
        final paragraphs = List.generate(
          30,
          (i) =>
              'Esta é a frase número ${i + 1} do capítulo em HTML, com texto suficiente para quebrar em várias linhas.',
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.white,
              body: Align(
                alignment: Alignment.topCenter,
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 400,
                    height: surfaceHeight,
                    child: RichReaderSurface(
                      chapter: FulltextChapter(
                        index: 0,
                        text: paragraphs.join('\n'),
                        html: paragraphs.map((p) => '<p>$p</p>').join(),
                      ),
                      settings: settings,
                      background: Colors.white,
                      foreground: Colors.black,
                      bodyStyle: TextStyle(
                        fontSize: 16,
                        height: lineHeight,
                        fontFamily: 'Ahem',
                        color: Colors.black,
                      ),
                      headingStyle: const TextStyle(
                        fontSize: 24,
                        fontFamily: 'Ahem',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        var pages = 0;
        for (var page = 0; page < 40; page++) {
          // The page indicator ("n / m") is ink too: only look above it.
          final rows = (await _inkRows(
            tester,
            boundary,
          )).where((y) => y < surfaceHeight - 28).toList();
          final heights = _lineHeights(rows);
          expect(
            heights,
            isNotEmpty,
            reason: 'page $page (surface $surfaceHeight) is blank',
          );
          // Ahem draws every glyph as a full square, so a whole line has the full height
          // of the tallest run on the page; a cut line is shorter.
          final whole = heights.reduce((a, b) => a > b ? a : b);
          expect(
            heights.where((h) => h != whole),
            isEmpty,
            reason: 'page $page has a line drawn cut: ink run heights $heights',
          );
          pages++;
          final before =
              (tester
                      .widget<SingleChildScrollView>(
                        find.byKey(const ValueKey('rich-reader-viewport')),
                      )
                      .controller!)
                  .offset;
          await tester.tapAt(
            const Offset(560, 100),
          ); // the right edge turns the page
          await tester.pumpAndSettle();
          final after =
              (tester
                      .widget<SingleChildScrollView>(
                        find.byKey(const ValueKey('rich-reader-viewport')),
                      )
                      .controller!)
                  .offset;
          if (after == before) break;
        }
        expect(pages, greaterThan(3));
      },
    );
  }
}

void _fractionalViewport() {
  testWidgets(
    'the page viewport is a whole number of device pixels at a fractional pixel ratio',
    (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      tester.view.devicePixelRatio = 2.25;
      tester.view.physicalSize = const Size(900, 1500);
      addTearDown(tester.view.reset);
      final paragraphs = List.generate(
        20,
        (i) =>
            'Frase número ${i + 1} para paginar o capítulo em várias páginas.',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichReaderSurface(
              chapter: FulltextChapter(
                index: 0,
                text: paragraphs.join('\n'),
                html: paragraphs.map((p) => '<p>$p</p>').join(),
              ),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 16, height: 1.6),
              headingStyle: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const ValueKey('rich-reader-viewport')))
          .height;
      final device = height * 2.25;
      expect(
        (device - device.roundToDouble()).abs(),
        lessThan(1e-6),
        reason: 'viewport $height dp = $device px',
      );
    },
  );
}
