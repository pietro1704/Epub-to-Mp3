import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';

void main() {
  testWidgets(
    'rich pagination retains markup and chrome changes keep the raw offset',
    (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      final height = ValueNotifier(400.0);
      addTearDown(height.dispose);
      final text = List.generate(
        60,
        (i) => 'Paragraph $i with bold words and ação 🐧.',
      ).join('\n');
      final html = List.generate(
        60,
        (i) => '<p>Paragraph $i with <b>bold words</b> and ação 🐧.</p>',
      ).join();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) => SizedBox(
                  width: 600,
                  height: value,
                  child: RichReaderSurface(
                    chapter: FulltextChapter(index: 0, text: text, html: html),
                    settings: settings,
                    background: Colors.white,
                    foreground: Colors.black,
                    bodyStyle: const TextStyle(fontSize: 20),
                    headingStyle: const TextStyle(fontSize: 24),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Html), findsOneWidget);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('rich-reader-viewport')),
          )
          .controller!;
      await tester.tapAt(const Offset(650, 180));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      final offset = scroll.offset;
      height.value = 500;
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      height.value = 400;
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a final-line anchor restores the measured last page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const target = 'MARCOZULU';
    final paragraphs = [
      ...List.generate(30, (i) => 'Paragraph $i with ação 🐧.'),
      target,
    ];
    final text = paragraphs.join('\n');
    final html = paragraphs.map((paragraph) => '<p>$paragraph</p>').join();
    final anchor = text.substring(0, text.indexOf(target)).runes.length;

    var reachedEnd = false;
    Future<void> open(int offset) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 600,
                height: 400,
                child: RichReaderSurface(
                  key: ValueKey(offset),
                  chapter: FulltextChapter(index: 0, text: text, html: html),
                  settings: settings,
                  background: Colors.white,
                  foreground: Colors.black,
                  bodyStyle: const TextStyle(fontSize: 20, height: 1.6),
                  headingStyle: const TextStyle(fontSize: 24),
                  initialSourceOffset: offset,
                  onNextChapter: () {
                    reachedEnd = true;
                    return false;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double scrollOffset() => tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('rich-reader-viewport')),
        )
        .controller!
        .offset;

    await open(0);
    for (var page = 0; page < paragraphs.length && !reachedEnd; page++) {
      await tester.tapAt(const Offset(650, 180));
      await tester.pumpAndSettle();
    }
    expect(reachedEnd, isTrue);
    final lastPageOffset = scrollOffset();
    expect(lastPageOffset, greaterThan(0));

    await open(anchor);
    expect(scrollOffset(), lastPageOffset);
  });

  test(
    'original typography respects persisted explicit choices and reset',
    () async {
      SharedPreferences.setMockInitialValues({'readerFontSize': 2});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      expect(settings.readerOverrideFontSize, true);
      expect(settings.readerOverrideFontFamily, false);
      await settings.resetReaderTypography();
      expect(settings.readerOverrideFontSize, false);
      await settings.setReaderFontSize(3);
      expect(settings.readerOverrideFontSize, true);
    },
  );

  testWidgets('selected text offers Play from here at the selection start', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'scrolling'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    final offsets = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: offsets.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Double-click a word of the second paragraph (it selects the word), then
    // open the desktop context menu on it with a secondary click.
    final second = tester.getRect(find.textContaining('Second', findRichText: true));
    final word = second.centerLeft + const Offset(20, 0);
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tapAt(
      word,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('Play from here'), findsOneWidget);
    await tester.tap(find.text('Play from here'));
    await tester.pump();
    expect(offsets, hasLength(1));
    expect(offsets.single, greaterThanOrEqualTo(text.indexOf('Second')));
    expect(offsets.single, lessThan(text.indexOf('Second') + 8),
        reason: 'the start of the second paragraph, not the first');
  });

  Future<void> pumpSelectionMenu(
    WidgetTester tester, {
    List<ReaderSavedHighlight> saved = const [],
    ValueChanged<TextRange>? onHighlight,
    ValueChanged<TextRange>? onAddNote,
    ValueChanged<String>? onRemoveHighlight,
  }) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'scrolling'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: (_) {},
              savedHighlights: saved,
              onHighlight: onHighlight,
              onAddNote: onAddNote,
              onRemoveHighlight: onRemoveHighlight,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final second = tester.getRect(find.textContaining('Second', findRichText: true));
    final word = second.centerLeft + const Offset(20, 0);
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tapAt(word, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  testWidgets('selected text offers Highlight and Add Note with the selected source range', (tester) async {
    final highlighted = <TextRange>[];
    final noted = <TextRange>[];
    await pumpSelectionMenu(tester, onHighlight: highlighted.add, onAddNote: noted.add);
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    final start = text.indexOf('Second');

    await tester.tap(find.text('Highlight'));
    await tester.pumpAndSettle();
    expect(highlighted, [TextRange(start: start, end: start + 'Second'.length)]);

    await pumpSelectionMenu(tester, onHighlight: highlighted.add, onAddNote: noted.add);
    await tester.tap(find.text('Add Note'));
    await tester.pumpAndSettle();
    expect(noted, [TextRange(start: start, end: start + 'Second'.length)]);
  });

  testWidgets('a selection over a saved highlight offers Remove highlight instead', (tester) async {
    final removed = <String>[];
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    final start = text.indexOf('Second');
    await pumpSelectionMenu(
      tester,
      saved: [
        ReaderSavedHighlight(
          id: 'h1',
          range: TextRange(start: start, end: start + 6),
          color: const Color(0x66ffcc00),
        ),
      ],
      onHighlight: (_) {},
      onRemoveHighlight: removed.add,
    );
    expect(find.text('Highlight'), findsNothing);
    await tester.tap(find.text('Remove highlight'));
    await tester.pumpAndSettle();
    expect(removed, ['h1']);
  });

  // Linux run 2026-11-25: in the default paginated layout a double-click or a drag on the
  // text never selected it, so Play from here was unreachable with a mouse.
  testWidgets('paginated layout: a single mouse click on the page centre toggles the chrome once the double-click window passes', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    final offsets = <int>[];
    var centerTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: offsets.add,
              onCenterTap: () => centerTaps++,
              onNextChapter: () => false,
              onPreviousChapter: () => false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final centre = tester.getRect(find.textContaining('Second', findRichText: true)).center;
    await tester.tapAt(centre, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(centerTaps, 0, reason: 'waits to see whether it is a double-click');
    await tester.pump(kDoubleTapTimeout);
    expect(centerTaps, 1);
  });

  testWidgets('paginated layout: a desktop double-click selects and offers Play from here', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    final offsets = <int>[];
    var centerTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: offsets.add,
              onCenterTap: () => centerTaps++,
              onNextChapter: () => false,
              onPreviousChapter: () => false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Double-click a word of the second paragraph (it selects the word), then
    // open the desktop context menu on it with a secondary click.
    final second = tester.getRect(find.textContaining('Second', findRichText: true));
    final word = second.center; // outside the page-turn edge zones
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tapAt(
      word,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(centerTaps, 0, reason: 'a double-click on text selects; it does not toggle the chrome');
    expect(find.text('Play from here'), findsOneWidget);
    await tester.tap(find.text('Play from here'));
    await tester.pump();
    expect(offsets, hasLength(1));
    expect(offsets.single, greaterThanOrEqualTo(text.indexOf('Second')));
    expect(offsets.single, lessThan(text.length),
        reason: 'the clicked word of the second paragraph, not the first');
  });

  testWidgets('paginated layout: a mouse drag over the text does not turn the page (it is left to text selection)', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    final offsets = <int>[];
    var centerTaps = 0;
    var chapterTurns = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: offsets.add,
              onCenterTap: () => centerTaps++,
              onNextChapter: () {
                chapterTurns++;
                return false;
              },
              onPreviousChapter: () {
                chapterTurns++;
                return false;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final second = tester.getRect(find.textContaining('Second', findRichText: true));
    final gesture = await tester.startGesture(second.center, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    for (var step = 1; step <= 6; step++) {
      await gesture.moveTo(second.center + Offset(step * 20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(chapterTurns, 0, reason: 'a mouse drag selects; it does not turn the page');
    expect(centerTaps, 0);
  });

  testWidgets('Play from here leaves selection mode: the selection is cleared and the action bar closes', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'scrolling'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    const text = 'First paragraph is here.\nSecond paragraph follows now.';
    const html = '<p>First paragraph is here.</p><p>Second paragraph follows now.</p>';
    final offsets = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: text, html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onPlayFromHere: offsets.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final second = tester.getRect(find.textContaining('Second', findRichText: true));
    final word = second.centerLeft + const Offset(20, 0);
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tapAt(word, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final notifier = tester.widget<SelectionListener>(find.byType(SelectionListener)).selectionNotifier;
    expect(notifier.selection.status, SelectionStatus.uncollapsed, reason: 'a word is selected');

    await tester.tap(find.text('Play from here'));
    await tester.pumpAndSettle();

    expect(offsets, hasLength(1), reason: 'playback starts from the selection');
    expect(find.text('Play from here'), findsNothing, reason: 'the action bar is closed');
    expect(notifier.selection.status, isNot(SelectionStatus.uncollapsed), reason: 'the selection is cleared');
  });

  testWidgets('without a play callback the text is not selectable', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'scrolling'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: 'One.', html: '<p>One.</p>'),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectableRegion), findsNothing);
  });


  // Mirror of Apple #1391 (PAGE-TAP): a paginated chapter that falls back to scrolling
  // (a fragment taller than the page) turns one screen per edge tap; only at either
  // end does the tap go to the neighbouring chapter.
  // Linux run 2026-11-25: on a maximized window the text sits in a centered column and a click
  // near the window edge did nothing. Like the iPhone, the edge zones span the whole reader.
  testWidgets('with a narrower text column the window edges still turn the chapter', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    var next = 0, previous = 0;
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RichReaderSurface(
          chapter: FulltextChapter(index: 0, text: 'Title\nAuthor', html: '<h1>Title</h1><p>Author</p>'),
          settings: settings,
          maxColumnWidth: 600,
          background: Colors.white,
          foreground: Colors.black,
          bodyStyle: const TextStyle(fontSize: 20),
          headingStyle: const TextStyle(fontSize: 24),
          onNextChapter: () { next++; return true; },
          onPreviousChapter: () { previous++; return true; },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Title')).dx, greaterThan(400),
        reason: 'the text stays in the centered column');

    await tester.tapAt(const Offset(1350, 300));
    await tester.pumpAndSettle();
    expect(next, 1);
    await tester.tapAt(const Offset(50, 300));
    await tester.pumpAndSettle();
    expect(previous, 1);
  });

  testWidgets('edge taps scroll one screen in a chapter that fell back to scrolling', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    final paragraphs = [
      ...List.generate(20, (i) => 'Paragraph $i before.'),
      'TALL',
      ...List.generate(20, (i) => 'Paragraph $i after.'),
    ];
    final html = paragraphs
        .map((p) => p == 'TALL'
            ? '<p style="font-size:500px">T</p>'
            : '<p>$p</p>')
        .join();
    var next = 0, previous = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 600,
            height: 400,
            child: RichReaderSurface(
              chapter: FulltextChapter(index: 0, text: paragraphs.join('\n'), html: html),
              settings: settings,
              background: Colors.white,
              foreground: Colors.black,
              bodyStyle: const TextStyle(fontSize: 20),
              headingStyle: const TextStyle(fontSize: 24),
              onNextChapter: () { next++; return false; },
              onPreviousChapter: () { previous++; return false; },
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(find.byKey(const ValueKey('rich-reader-viewport')))
        .controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(800));

    await tester.tapAt(const Offset(110, 180));
    await tester.pumpAndSettle();
    expect(previous, 1, reason: 'at the start a back tap goes to the previous chapter');

    await tester.tapAt(const Offset(650, 180));
    await tester.pumpAndSettle();
    expect(next, 0);
    expect(scroll.offset, inInclusiveRange(300, 400));

    await tester.tapAt(const Offset(110, 180));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(previous, 1);

    for (var i = 0; i < 40 && next == 0; i++) {
      await tester.tapAt(const Offset(650, 180));
      await tester.pumpAndSettle();
    }
    expect(scroll.offset, scroll.position.maxScrollExtent);
    expect(next, 1);
    expect(tester.takeException(), isNull);
  });

  // A8 run 2026-11-25: with "Play from here" on (SelectionArea), a touch tap on the
  // middle of a paginated page never brought the reader chrome back.
  for (final layout in ['paginated', 'scrolling']) {
    testWidgets('a touch tap on selectable text toggles the chrome ($layout)', (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': layout});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      final text = List.generate(8, (i) => 'Paragraph $i of plain text.').join('\n');
      final html = List.generate(8, (i) => '<p>Paragraph $i of plain text.</p>').join();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: RichReaderSurface(
                chapter: FulltextChapter(index: 0, text: text, html: html),
                settings: settings,
                background: Colors.white,
                foreground: Colors.black,
                bodyStyle: const TextStyle(fontSize: 20),
                headingStyle: const TextStyle(fontSize: 24),
                onPlayFromHere: (_) {},
                onCenterTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final word = tester.getRect(find.textContaining('Paragraph 1', findRichText: true));
      await tester.tapAt(Offset(300, word.center.dy));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  }
}
