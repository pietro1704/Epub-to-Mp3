// Pagination of the rich reader: no blank last page, and the guards that hide the
// neighbouring line cover its ink overflow (glyph tops/accents poke above the line box).
import 'dart:ui';

import 'package:flutter_app/features/reader/reader_document_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the last page is never made only of the document padding', () {
    // Three lines of 20 px between 16 px of padding: height 92. Viewport 40 fits two.
    final geometry = ReaderDocumentGeometry(92, [
      for (var i = 0; i < 3; i++) Rect.fromLTWH(0, 16.0 + i * 20, 100, 20),
    ], const []);
    final pages = geometry.pageOffsets(36);
    // Page 1 holds lines 0-1 (16..56 does not fit 36 -> line 0 only), and so on; the
    // important part: no page starts after the last line's bottom (76).
    expect(
      pages.every((offset) => offset < 76),
      isTrue,
      reason: 'pages: $pages',
    );
    // And the last page does hold the last line.
    expect(pages.last + 36 >= 76, isTrue, reason: 'pages: $pages');
  });

  test('document with trailing padding only: 8 px beyond the viewport adds no page', () {
    final geometry = ReaderDocumentGeometry(2936, [
      for (var i = 0; i < 90; i++) Rect.fromLTWH(0, 16.0 + i * 32, 100, 32),
    ], const []);
    final pages = geometry.pageOffsets(305);
    expect(pages.last + 305, greaterThanOrEqualTo(16.0 + 89 * 32 + 32));
    expect(
      pages.last,
      lessThan(16.0 + 89 * 32 + 32),
      reason: 'a page that starts after the last line is blank',
    );
  });

  test('guards also hide the few pixels of ink that pass the edge of the neighbouring line box', () {
    // Seen on the SM-X620: the tops of ascenders and parentheses of the next line showed
    // as a dotted sliver under the last whole line.
    final geometry = ReaderDocumentGeometry(400, [
      Rect.fromLTWH(0, 90, 100, 20),
      Rect.fromLTWH(0, 190, 100, 20),
    ], const []);
    // Viewport 0..100: the line 90..110 crosses the bottom edge.
    final (_, bottom) = geometry.edgeGuards(0, 100);
    expect(bottom, greaterThan(100 - 90));
    // Viewport 100..200: the line 90..110 crosses the top edge.
    final (top, _) = geometry.edgeGuards(100, 100);
    expect(top, greaterThan(110 - 100));
  });
}
