import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/views/reader_search_overlay.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: child),
  );
}

final _chapters = [
  const FulltextChapter(
    index: 0,
    name: 'Prologue',
    text: 'The quick brown fox jumps over the lazy dog near the river bank.',
  ),
  const FulltextChapter(
    index: 1,
    name: 'Chapter 1',
    text: 'Alice went through the looking glass and found a strange new world.',
  ),
  const FulltextChapter(
    index: 2,
    name: 'Chapter 2',
    text: 'The fox returned to the forest after a long journey through the fields.',
  ),
];

void main() {
  group('ReaderSearchOverlay', () {
    testWidgets('shows search field and Done button', (tester) async {
      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: _chapters,
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('shows "No results" for non-matching query', (tester) async {
      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: _chapters,
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzzznotfound');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('finds matches across chapters', (tester) async {
      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: _chapters,
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // "fox" appears in chapter 0 and chapter 2
      await tester.enterText(find.byType(TextField), 'fox');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // Should find chapter titles
      expect(find.text('Prologue'), findsOneWidget);
      expect(find.text('Chapter 2'), findsOneWidget);
    });

    testWidgets('case-insensitive search works', (tester) async {
      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: _chapters,
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ALICE');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Chapter 1'), findsOneWidget);
    });

    testWidgets('caps at 100 results', (tester) async {
      // Build a chapter with >100 occurrences of "x"
      final manyMatches = List.generate(110, (_) => 'x word').join(' ');
      final bigChapter = FulltextChapter(
        index: 0,
        name: 'Big',
        text: manyMatches,
      );

      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: [bigChapter],
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // The capped message should appear
      expect(find.text('Showing first 100 results'), findsOneWidget);
    });

    testWidgets('clear button resets results', (tester) async {
      await tester.pumpWidget(_wrap(
        ReaderSearchOverlay(
          chapters: _chapters,
          onJumpToChapter: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'fox');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Prologue'), findsOneWidget);

      // Tap clear
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      expect(find.text('Prologue'), findsNothing);
    });
  });
}
