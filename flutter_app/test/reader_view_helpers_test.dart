// Unit tests for the pure helpers in views/reader_view.dart.
// Mirrors iOS `EpubHtmlRenderer` heading cap (8485ab2) and the
// `readerTextAlignment` enum → `TextAlign` translation.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  group('cappedHeadingSize', () {
    test('returns body + 6 when below the 1.5x cap', () {
      // body 20pt → designed 26 < cap 30 → designed wins.
      expect(cappedHeadingSize(20), 26);
    });

    test('clamps to 1.5x body when designed exceeds the cap', () {
      // body 10pt → designed 16 > cap 15 → cap wins.
      expect(cappedHeadingSize(10), 15);
    });

    test('respects custom scale', () {
      // body 20pt, scale 1.2 → cap 24 vs designed 26 → cap wins.
      expect(cappedHeadingSize(20, scale: 1.2), 24);
    });

    test('edge: equal designed and cap returns the value', () {
      // body 12pt → designed 18, cap 18 → tie → cap branch (designed
      // is NOT strictly less than cap, so returns cap).
      expect(cappedHeadingSize(12), 18);
    });
  });

  group('flutterTextAlign', () {
    test('justified maps to TextAlign.justify', () {
      expect(
        flutterTextAlign(ReaderTextAlignment.justified),
        TextAlign.justify,
      );
    });

    test('left maps to TextAlign.left', () {
      expect(
        flutterTextAlign(ReaderTextAlignment.left),
        TextAlign.left,
      );
    });
  });
}
