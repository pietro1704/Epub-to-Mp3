// Regression: in the paginated layout the middle column had no tap
// handler — left/right thirds called retreat/advance but the centre
// 50% was a dead zone. The user could not hide chrome because that
// surface is what fires `onCenterTap`. User-reported on Android
// 2026-05-22: "esconder chrome não funciona no Android."
//
// This test mounts `ReaderView` in paginated mode, taps the centre of
// the screen, and asserts `onCenterTap` fired exactly once. Mirrors
// the iOS tap-zone partition (`ReaderView.tapZones`) which has had
// the centre toggle since the SwiftUI version was written.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

FulltextChapter _chapter() => FulltextChapter(
      index: 1,
      name: 'Chapter 1',
      text:
          'First sentence here. Second sentence here. Third sentence here. '
          'Fourth sentence. Fifth sentence. Sixth one too. Seventh and so on.',
    );

Future<SharedPreferences> _prefs(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues({
    'readerLayout': ReaderLayout.paginated.rawValue,
    ...seed,
  });
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, Widget child) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('ReaderView paginated centre tap', () {
    testWidgets('tap in the middle fires onCenterTap', (t) async {
      final prefs = await _prefs(const {});
      var taps = 0;
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          chapter: _chapter(),
          spans: const [],
          onCenterTap: () => taps++,
        ),
      ));
      await t.pumpAndSettle();

      // Default Flutter test surface is 800x600. The paginated layout
      // splits the width 1/2/1: left 200, middle 400 (x 200…600),
      // right 200. Tap at dead centre.
      await t.tapAt(const Offset(400, 300));
      await t.pumpAndSettle();

      expect(
        taps,
        1,
        reason:
            'paginated layout middle column must forward centre taps to onCenterTap '
            '(chrome toggle); see commit b49bedb follow-up',
      );
    });

    testWidgets('tap on left third still calls page retreat, not centre',
        (t) async {
      final prefs = await _prefs(const {});
      var centreTaps = 0;
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          chapter: _chapter(),
          spans: const [],
          onCenterTap: () => centreTaps++,
        ),
      ));
      await t.pumpAndSettle();

      // x = 80 is inside the left 25% (page-retreat zone) on 800-wide surface.
      await t.tapAt(const Offset(80, 300));
      await t.pumpAndSettle();

      expect(
        centreTaps,
        0,
        reason:
            'left third is the page-retreat zone — must NOT forward to onCenterTap',
      );
    });

    testWidgets('tap on right third still calls page advance, not centre',
        (t) async {
      final prefs = await _prefs(const {});
      var centreTaps = 0;
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          chapter: _chapter(),
          spans: const [],
          onCenterTap: () => centreTaps++,
        ),
      ));
      await t.pumpAndSettle();

      // x = 720 is inside the right 25% (page-advance zone) on 800-wide surface.
      await t.tapAt(const Offset(720, 300));
      await t.pumpAndSettle();

      expect(
        centreTaps,
        0,
        reason:
            'right third is the page-advance zone — must NOT forward to onCenterTap',
      );
    });
  });
}
