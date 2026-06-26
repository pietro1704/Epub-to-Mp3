// Mirror of iOS commit 371b204 (scroll-mode white-band fix).
//
// iOS context: in continuous-scroll mode a `BookChapterCell` whose async
// HTML render hadn't finished showed a fixed 120 pt `Color.clear`
// placeholder, so a fast scroll flashed white bands. Two iOS sub-fixes:
//   (a) size the placeholder to the chapter's ESTIMATED height (from
//       charCount) so scroll metrics stay stable, and
//   (b) paint the reader theme background behind the WHOLE continuous
//       ScrollView so any not-yet-rendered area shows the reader
//       background, never white.
//
// Flutter parity:
//   - Sub-fix (a) is N/A. The Flutter `ReaderView` renders exactly ONE
//     chapter, synchronously in `build()`. There is no `ListView.builder`
//     of lazily-materialised, async-rendering chapter cells — so there is
//     no short blank stub that jumps to full height. Nothing to estimate.
//   - Sub-fix (b) is the only piece with a Flutter analogue, and it WAS
//     incompletely implemented: `_scrollingLayout` wrapped the
//     `SingleChildScrollView` in `Container(color: bg)`, but that Container
//     shrink-wrapped its (content-sized) scroll child. A chapter shorter
//     than the viewport — or the Android overscroll-stretch zone on a fast
//     fling — left a strip below the text exposing the white system/Scaffold
//     background: exactly the iOS "white band". This commit gives that
//     Container `width/height: infinity` so the theme background paints the
//     WHOLE reader region, matching the iOS
//     `.background(themeBackground.ignoresSafeArea())`.
//
// This test mounts the scrolling layout on a Scaffold with a deliberately
// WHITE background, with content far shorter than the viewport, and asserts
// the reader paints its (non-white) theme background across the FULL reader
// region — so no white strip is ever exposed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';
import 'package:flutter_app/views/reader_view.dart';

FulltextChapter _chapter() => FulltextChapter(
      index: 1,
      name: 'Chapter 1',
      text: 'First sentence here. Second sentence here. Third sentence here.',
    );

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
      // White Scaffold so a missing reader background would be visible
      // as white — exactly the iOS "white band" failure mode.
      home: Scaffold(
        backgroundColor: Colors.white,
        body: child,
      ),
    ),
  );
}

void main() {
  group('ReaderView scrolling-mode theme background (iOS 371b204 parity)', () {
    testWidgets(
        'scroll layout paints the reader theme background (no white flash)',
        (t) async {
      // sepia is a non-white reader theme, so a missing background wrapper
      // would leave the white Scaffold showing through.
      final prefs = await _prefs({
        'readerTheme': ReaderTheme.sepia.rawValue,
      });

      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: _chapter(), spans: const []),
      ));
      await t.pumpAndSettle();

      final expectedBg = ReaderThemeColors.background(ReaderTheme.sepia);
      expect(
        expectedBg,
        isNot(Colors.white),
        reason: 'sanity: the sepia theme background must differ from white '
            'for this test to be meaningful',
      );

      // The reader must paint at least one Container whose color is the
      // sepia theme background. That is the wrapper standing between the
      // scroll content and the white Scaffold — the Flutter analogue of
      // iOS painting the theme background behind the whole ScrollView.
      final painted = find
          .byType(Container)
          .evaluate()
          .map((e) => e.widget as Container)
          .where((c) => c.color == expectedBg)
          .toList();

      expect(
        painted,
        isNotEmpty,
        reason:
            'scrolling layout must wrap its ScrollView in a theme-coloured '
            'Container so blank / overscroll regions never flash white '
            '(mirrors iOS continuousBookScroll .background(themeBackground))',
      );
    });

    testWidgets('background covers the full reader region', (t) async {
      final prefs = await _prefs({
        'readerTheme': ReaderTheme.dark.rawValue,
      });

      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: _chapter(), spans: const []),
      ));
      await t.pumpAndSettle();

      final expectedBg = ReaderThemeColors.background(ReaderTheme.dark);

      // Find every theme-coloured Container and assert at least one spans
      // the whole 800x600 test surface — i.e. there is no uncovered strip
      // where the white Scaffold could show through during overscroll.
      // (Inner content-sized Containers may also carry the colour, so we
      // look for the full-bleed one rather than asserting on `.first`.)
      final bgFinder = find.byWidgetPredicate(
        (w) => w is Container && w.color == expectedBg,
      );
      expect(bgFinder, findsWidgets);

      final sizes = bgFinder.evaluate().map((e) => t.getSize(find.byWidget(
            e.widget,
          ))).toList();
      final coversFull = sizes.any((s) => s.width == 800 && s.height == 600);
      expect(
        coversFull,
        isTrue,
        reason: 'a theme-coloured Container must span the full 800x600 reader '
            'region so no white strip is exposed on overscroll '
            '(found sizes: $sizes)',
      );
    });
  });
}
