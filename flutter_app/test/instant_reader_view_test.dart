import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';

EbookFulltext _sampleFulltext() => EbookFulltext.fromJson({
      'jobId': 'test-job',
      'bookTitle': 'Sample Book',
      'bookAuthor': 'Author Name',
      'chapters': [
        {
          'index': 0,
          'name': 'Introduction',
          'text':
              'This is the introduction chapter with enough text to be readable. It has multiple sentences for testing purposes and more.',
        },
        {
          'index': 1,
          'name': 'Chapter 1',
          'text':
              'This is chapter one with content. It continues with more text here. And even more content for testing.',
        },
      ],
    });

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, Widget child) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SizedBox(
        width: 400,
        height: 800,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('InstantReaderView', () {
    testWidgets('renders short non-empty front matter', (t) async {
      final prefs = await _mockPrefs();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'short-front-matter',
        'chapters': [
          {'index': 0, 'name': 'Dedication', 'text': 'To Ana.'},
          {'index': 1, 'name': 'Chapter 1', 'text': 'The story begins here.'},
        ],
      });
      await t.pumpWidget(_wrap(prefs, InstantReaderView(fulltext: fulltext)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('To Ana.'), findsOneWidget);
      expect(find.text('Dedication'), findsOneWidget);
    });

    testWidgets('shows settings button', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.text_format), findsOneWidget);
    });

    testWidgets('renders reader content without a player bar', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Author Name'), findsNothing);
    });

    testWidgets('does not render a play button in the reader', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });

    testWidgets('shows no content when fulltext is empty', (t) async {
      final prefs = await _mockPrefs();
      final empty = EbookFulltext.fromJson({
        'jobId': 'empty',
        'chapters': <Map<String, dynamic>>[],
      });
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: empty),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('No content available'), findsOneWidget);
    });

    Future<void> openMenu(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('reader-overflow-menu')));
      await t.pumpAndSettle();
    }

    Future<void> closeMenu(WidgetTester t) async {
      await t.tapAt(const Offset(4, 4));
      await t.pumpAndSettle();
    }

    EbookFulltext annotatedBook() => EbookFulltext.fromJson({
      'jobId': 'notes',
      'bookTitle': 'Annotated',
      'chapters': [
        {'index': 0, 'name': 'Plain opening', 'text': 'A plain opening chapter with prose.'},
        {
          'index': 1,
          'name': 'Annotated chapter',
          'text': 'A claim with a note.',
          'footnotes': [
            {'number': '1', 'text': 'The first cited source.'},
            {'text': 'A note without a label.'},
          ],
        },
        {'index': 2, 'name': 'Plain ending', 'text': 'A plain closing chapter.'},
      ],
    });

    Future<void> openChapter(WidgetTester t, String title) async {
      // Contents becomes the recent tool once used, so it may sit beside More.
      final recent = find.descendant(
        of: find.byKey(const ValueKey('reader-recent-tool')),
        matching: find.byIcon(Icons.list),
      );
      if (recent.evaluate().isNotEmpty) {
        await t.tap(find.byKey(const ValueKey('reader-recent-tool')));
      } else {
        await openMenu(t);
        await t.tap(find.byKey(const ValueKey('reader-menu-contents')));
      }
      await t.pumpAndSettle();
      await t.tap(find.text(title));
      await t.pumpAndSettle();
    }

    Future<bool> footnotesListed(WidgetTester t) async {
      await openMenu(t);
      final listed = find.byKey(const ValueKey('reader-menu-footnotes')).evaluate().isNotEmpty;
      await closeMenu(t);
      return listed;
    }

    testWidgets('Footnotes entry follows the chapter: absent, present, absent, present',
        (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: annotatedBook(), initialChapterIndex: 0),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(await footnotesListed(t), isFalse, reason: 'opening chapter has no notes');
      await openChapter(t, 'Annotated chapter');
      expect(await footnotesListed(t), isTrue);
      await openChapter(t, 'Plain ending');
      expect(await footnotesListed(t), isFalse);
      await openChapter(t, 'Annotated chapter');
      expect(await footnotesListed(t), isTrue, reason: 'returns with the chapter');

      await openMenu(t);
      await t.tap(find.byKey(const ValueKey('reader-menu-footnotes')));
      await t.pumpAndSettle();
      expect(find.text('Footnotes'), findsOneWidget);
      expect(find.text('The first cited source.'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('A note without a label.'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'unlabelled notes are numbered by position');
    });


    testWidgets('a pending player request opens the playing chapter once', (t) async {
      final prefs = await _mockPrefs();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'jump',
        'chapters': [
          {'index': 10, 'name': 'First', 'text': 'First chapter prose.'},
          {'index': 20, 'name': 'Second', 'text': 'Second chapter prose.'},
          {'index': 30, 'name': 'Third', 'text': 'Third chapter prose.'},
        ],
      });
      await t.pumpWidget(ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          readerPlaybackJumpProvider.overrideWith((ref) => (bookId: 'b1', chapterIndex: 1)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: InstantReaderView(fulltext: fulltext, bookId: 'b1')),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Second chapter prose.'), findsOneWidget);
      expect(
        ProviderScope.containerOf(t.element(find.byType(InstantReaderView)))
            .read(readerPlaybackJumpProvider),
        isNull,
        reason: 'the request is consumed',
      );
    });

    testWidgets('a request raised while open moves the reader; another book is ignored', (t) async {
      final prefs = await _mockPrefs();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'jump2',
        'chapters': [
          {'index': 10, 'name': 'First', 'text': 'First chapter prose.'},
          {'index': 20, 'name': 'Second', 'text': 'Second chapter prose.'},
        ],
      });
      await t.pumpWidget(_wrap(prefs, InstantReaderView(fulltext: fulltext, bookId: 'b1')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('First chapter prose.'), findsOneWidget);
      final container = ProviderScope.containerOf(t.element(find.byType(InstantReaderView)));

      container.read(readerPlaybackJumpProvider.notifier).state = (bookId: 'other', chapterIndex: 1);
      await t.pump();
      expect(find.text('First chapter prose.'), findsOneWidget);

      container.read(readerPlaybackJumpProvider.notifier).state = (bookId: 'b1', chapterIndex: 1);
      await t.pumpAndSettle();
      expect(find.text('Second chapter prose.'), findsOneWidget);
      expect(container.read(readerPlaybackJumpProvider), isNull);
    });

    testWidgets('the recent tool sits beside More and the others are in the menu', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs, InstantReaderView(fulltext: _sampleFulltext())));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.descendant(of: find.byKey(const ValueKey('reader-recent-tool')), matching: find.byIcon(Icons.text_format)), findsOneWidget);
      expect(find.byIcon(Icons.list), findsNothing, reason: 'no loose tool icons besides the recent one');
      expect(find.byIcon(Icons.search), findsNothing);

      await openMenu(t);
      for (final tool in ['contents', 'search', 'bookmarks', 'add-bookmark']) {
        expect(find.byKey(ValueKey('reader-menu-$tool')), findsOneWidget, reason: tool);
      }
      expect(find.byKey(const ValueKey('reader-menu-appearance')), findsNothing);
      expect(find.byKey(const ValueKey('reader-menu-footnotes')), findsNothing,
          reason: 'no notes in this chapter');
    });

    testWidgets('choosing a tool from More makes it the recent tool and persists', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs, InstantReaderView(fulltext: _sampleFulltext())));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      await openMenu(t);
      await t.tap(find.byKey(const ValueKey('reader-menu-search')));
      await t.pumpAndSettle();
      expect(prefs.getString('reader.recentTool.v1'), 'search');
      await closeMenu(t); // dismisses the search sheet through its barrier
      expect(find.descendant(of: find.byKey(const ValueKey('reader-recent-tool')), matching: find.byIcon(Icons.search)), findsOneWidget);
      await openMenu(t);
      expect(find.byKey(const ValueKey('reader-menu-appearance')), findsOneWidget,
          reason: 'the tool it replaced moves into the menu');
      expect(find.byKey(const ValueKey('reader-menu-search')), findsNothing);
    });

    testWidgets('Footnotes as recent tool stands down where there are no notes', (t) async {
      final prefs = await _mockPrefs({'reader.recentTool.v1': 'footnotes'});
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: annotatedBook(), initialChapterIndex: 0),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      Finder recent(IconData icon) => find.descendant(
        of: find.byKey(const ValueKey('reader-recent-tool')),
        matching: find.byIcon(icon),
      );
      expect(recent(Icons.text_format), findsOneWidget, reason: 'plain chapter shows the appearance tool');
      expect(prefs.getString('reader.recentTool.v1'), 'footnotes', reason: 'standing down does not forget the tool');

      // Reopen on the annotated chapter: the remembered tool returns.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: annotatedBook(), initialChapterIndex: 1),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(recent(Icons.notes), findsOneWidget, reason: 'the remembered tool returns with notes');
    });

  });
}
