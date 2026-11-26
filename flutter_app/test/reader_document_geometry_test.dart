import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/features/reader/reader_document_geometry.dart';

void main() {
  test(
    'pagination protects complete glyph fragments across page boundaries',
    () {
      final geometry = ReaderDocumentGeometry(300, [
        for (var i = 0; i < 10; i++) Rect.fromLTWH(0, i * 30, 100, 28),
      ], []);
      final pages = geometry.pageOffsets(100);
      expect(pages, [0, 90, 180, 270]);
      for (final offset in pages.skip(1)) {
        expect(
          geometry.fragments.any(
            (line) => line.top < offset && line.bottom > offset,
          ),
          false,
        );
      }
    },
  );

  test('oversized images select scrolling rather than clipping', () {
    final geometry = ReaderDocumentGeometry(900, [
      const Rect.fromLTWH(0, 0, 200, 800),
    ], []);
    expect(geometry.pageOffsets(300), isEmpty);
  });

  test('edge guards hide partial glyphs without changing the raw offset', () {
    final geometry = ReaderDocumentGeometry(200, [
      const Rect.fromLTWH(0, 20, 100, 30),
      const Rect.fromLTWH(0, 120, 100, 30),
    ], []);
    // The fragment's own extent plus the ink margin that passes a line box.
    const ink = ReaderDocumentGeometry.inkOverflow;
    expect(geometry.edgeGuards(30, 100), (20 + ink, 10 + ink));
  });

  test('the guard hides the cut line but never reaches the descenders of the last whole line', () {
    // 20 px lines, 4 px leading; the viewport ends inside the fourth line.
    final geometry = ReaderDocumentGeometry(200, [
      for (var i = 0; i < 4; i++) Rect.fromLTWH(0, i * 24.0, 100, 20),
    ], []);
    const viewport = 90.0;
    final (_, bottom) = geometry.edgeGuards(0, viewport);
    expect(bottom, greaterThan(0), reason: 'the partly visible line must be covered');
    const lastWholeLineBottom = 2 * 24.0 + 20;
    expect(viewport - bottom, greaterThanOrEqualTo(lastWholeLineBottom), reason: 'g, j, p, q of the last whole line stay visible');
  });

  test(
    'normalized text retains Unicode UTF-16 positions and repeated passages',
    () {
      final text = NormalizedReaderText('  Ação 🐧\n\nAgain.  Again. ');
      expect(text.text, 'Ação 🐧 Again. Again.');
      expect(text.offsets.first, 2);
      expect(text.offsets[text.text.lastIndexOf('Again.')], 19);
    },
  );

  testWidgets('a selection offset maps to the source offset of its paragraph', (tester) async {
    final key = GlobalKey();
    const source = 'Alpha one.\nBeta two here.\nGamma three.';
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: Column(
              key: key,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [Text('Alpha one.'), Text('Beta two here.'), Text('Gamma three.')],
            ),
          ),
        ),
      ),
    );
    final geometry = ReaderDocumentGeometry.measure(
      key.currentContext!.findRenderObject()! as RenderBox,
      source,
    );
    expect(geometry.segments.map((s) => s.length), [10, 14, 12]);
    // Content offsets run across paragraphs without separators.
    expect(geometry.sourceOffsetForContentOffset(0), 0);
    expect(geometry.sourceOffsetForContentOffset(3), 3);
    expect(geometry.sourceOffsetForContentOffset(10 + 5), source.indexOf('Beta') + 5);
    expect(geometry.sourceOffsetForContentOffset(10 + 14 + 6), source.indexOf('Gamma') + 6);
    expect(geometry.sourceOffsetForContentOffset(36), isNull, reason: 'past the last paragraph');
  });

}
