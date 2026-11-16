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
    expect(geometry.edgeGuards(30, 100), (20, 10));
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
}
