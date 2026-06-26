// Mirror of the iOS reader-flicker / chapter-cross batch:
//   d473109 fix(ios): eliminate reader flicker on page turn,
//           chapter switch, chrome toggle  (CONTENT-equality gate)
//   6ab6609 fix(ios): page-turn off last/first page crosses chapter
//           boundary  (deterministic chapterToken swap)
//   d069e9a fix(ios): no wrong-page flash when a page turn crosses a
//           chapter  (re-seed to fresh pages once, no stale frame)
//   fbe8ea3 fix(ios): reader respects safe area when chrome is hidden
//           (safe-area top/bottom is an inviolable padding floor)
//
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// The Flutter reader is a single stateful widget that swaps page
// content via setState(_currentPage), not a UIPageViewController with
// reused controllers — so several of the iOS UIKit-specific symptoms
// cannot occur here. These tests pin the BEHAVIOURS that do apply:
//   * a fresh-but-identical spans list must not repaginate (flicker)
//   * a chapter swap (token change) must re-seed to page 0 off the
//     fresh pages, even when two chapters share a page count
//   * the system safe-area inset is honoured as a padding floor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

SentenceSpan _span(int i, String text) =>
    SentenceSpan(id: 's$i', text: text, startChar: 0, endChar: text.length);

FulltextChapter _chapter(int index, String text) =>
    FulltextChapter(index: index, name: 'Chapter $index', text: text);

Future<SharedPreferences> _prefs([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues({
    'readerLayout': ReaderLayout.paginated.rawValue,
    ...seed,
  });
  return SharedPreferences.getInstance();
}

Widget _wrap(
  SharedPreferences prefs,
  Widget child, {
  EdgeInsets viewPadding = EdgeInsets.zero,
}) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          // Preserve the real test surface size; only override the
          // safe-area padding so `MediaQueryData()` doesn't zero the
          // size (which would collapse the tap-zone widths).
          data: MediaQuery.of(context).copyWith(padding: viewPadding),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
}

void main() {
  group('spansContentEqual (iOS d473109 content-vs-pointer gate)', () {
    test('identical reference is equal', () {
      final a = [_span(0, 'one'), _span(1, 'two')];
      expect(spansContentEqual(a, a), isTrue);
    });

    test('fresh list with content-equal spans is equal', () {
      // This is the flicker case: a parent rebuild re-runs
      // splitSentences() and hands back a brand-new list whose spans
      // are value-equal. Must compare equal so didUpdateWidget does
      // NOT repaginate.
      final a = [_span(0, 'one'), _span(1, 'two')];
      final b = [_span(0, 'one'), _span(1, 'two')];
      expect(identical(a, b), isFalse);
      expect(spansContentEqual(a, b), isTrue);
    });

    test('different length is not equal', () {
      expect(
        spansContentEqual([_span(0, 'one')], [_span(0, 'one'), _span(1, 'x')]),
        isFalse,
      );
    });

    test('different text is not equal', () {
      expect(
        spansContentEqual([_span(0, 'one')], [_span(0, 'ONE')]),
        isFalse,
      );
    });
  });

  group('chapter-token swap (iOS 6ab6609 / d069e9a)', () {
    testWidgets(
        'swap re-seeds to page 1 of the new chapter even when page counts match',
        (t) async {
      final prefs = await _prefs();
      // Two chapters with the SAME number of pages. On iOS a count-based
      // latch stayed armed forever here; the deterministic chapterToken
      // must still re-seed. Each chapter is short → exactly 1 page.
      final chA = _chapter(1, 'Alpha alpha alpha.');
      final chB = _chapter(2, 'Bravo bravo bravo.');

      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: const ValueKey('reader'),
          chapter: chA,
          spans: chA.splitSentences(),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('1 / 1'), findsOneWidget);
      expect(find.textContaining('Alpha'), findsWidgets);

      // Swap to chapter B (same widget key → didUpdateWidget, not a
      // fresh State). Content must flip to chapter B's first page.
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: const ValueKey('reader'),
          chapter: chB,
          spans: chB.splitSentences(),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.textContaining('Bravo'), findsWidgets,
          reason: 'token swap must show the new chapter, not a stale frame');
      expect(find.textContaining('Alpha'), findsNothing,
          reason: 'old chapter content must not linger after the swap');
    });

    testWidgets('multi-page chapter swap re-seeds to page 1 (no carried index)',
        (t) async {
      final prefs = await _prefs();
      // > 1500 chars so the paginator emits at least 2 pages.
      final longText = List.generate(
        120,
        (i) => 'This is sentence number $i in a deliberately long chapter.',
      ).join(' ');
      final chA = _chapter(1, longText);
      final chB = _chapter(2, 'Short bravo chapter.');

      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: const ValueKey('reader'),
          chapter: chA,
          spans: chA.splitSentences(),
        ),
      ));
      await t.pumpAndSettle();

      // Advance to page 2 of chapter A via the right tap zone.
      await t.tapAt(const Offset(720, 300));
      await t.pumpAndSettle();
      expect(find.textContaining('2 /'), findsOneWidget);

      // Swap chapter — must land on page 1 of B, not carry page index 2.
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: const ValueKey('reader'),
          chapter: chB,
          spans: chB.splitSentences(),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('1 / 1'), findsOneWidget,
          reason: 'fresh chapter must re-seed to its first page');
      expect(find.textContaining('Short bravo'), findsWidgets);
    });
  });

  group('safe area floor (iOS fbe8ea3)', () {
    testWidgets('paginated body top padding includes the notch inset',
        (t) async {
      final prefs = await _prefs();
      final ch = _chapter(1, 'Hello world. This is the page body text.');

      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(chapter: ch, spans: ch.splitSentences()),
        viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
      ));
      await t.pumpAndSettle();

      // Find the SingleChildScrollView wrapping the page body and assert
      // its top padding cleared the 59pt notch (59 + 24 reader pad).
      final scrollViews = t
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .where((s) => s.padding is EdgeInsets)
          .toList();
      final withNotchFloor = scrollViews.any((s) {
        final p = s.padding as EdgeInsets;
        return p.top >= 59 && p.bottom >= 34;
      });
      expect(withNotchFloor, isTrue,
          reason:
              'safe-area top/bottom must be an inviolable padding floor so the '
              'first line clears the notch when chrome is hidden');
    });
  });
}
