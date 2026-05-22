// Regression: when the EPUB chapter ships with a `html` body, the
// scrolling reader must render through `flutter_html` so the EPUB's
// own formatting (bold, italic, headings) survives. The plain-span
// path is the fallback for chapters that have no HTML.
//
// User-reported on Android 2026-05-22: "formatação não segue a
// original do epub" — the reader was always rendering plain
// `SentenceSpan` text regardless of whether the chapter had HTML.

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

Future<SharedPreferences> _prefs(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues({
    'readerLayout': ReaderLayout.scrolling.rawValue,
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
  group('ReaderView scrolling HTML rendering', () {
    testWidgets('uses Html widget when chapter.html is non-empty',
        (t) async {
      final prefs = await _prefs(const {});
      final chapter = FulltextChapter(
        index: 1,
        name: 'Chapter 1',
        text: 'Plain fallback text.',
        html: '<p>Body paragraph with <b>bold</b> and <i>italic</i>.</p>',
      );
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: chapter, spans: const []),
      ));
      await t.pumpAndSettle();

      expect(
        find.byType(Html),
        findsOneWidget,
        reason: 'scrolling mode must mount an Html widget when chapter.html '
            'is present, so the EPUB\'s native formatting survives',
      );
    });

    testWidgets('falls back to span Text when chapter.html is null',
        (t) async {
      final prefs = await _prefs(const {});
      final chapter = FulltextChapter(
        index: 1,
        name: 'Chapter 1',
        text: 'Plain body content here.',
      );
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: chapter, spans: const []),
      ));
      await t.pumpAndSettle();

      expect(
        find.byType(Html),
        findsNothing,
        reason: 'no HTML body → must use the plain-span path so the '
            'reader is not blank',
      );
    });

    testWidgets('falls back to span Text when chapter.html is whitespace',
        (t) async {
      final prefs = await _prefs(const {});
      final chapter = FulltextChapter(
        index: 1,
        name: 'Chapter 1',
        text: 'Plain body.',
        html: '   \n  ',
      );
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: chapter, spans: const []),
      ));
      await t.pumpAndSettle();

      expect(
        find.byType(Html),
        findsNothing,
        reason: 'whitespace-only HTML body counts as empty — fall back '
            'to spans so the user does not stare at a blank Html widget',
      );
    });
  });
}
