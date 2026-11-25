// Pietro: in paginated mode the page area reserves the space of the bars, so the
// text never moves when the chrome is shown or hidden (A8: the viewport grew by
// the top bar's height and the text jumped).
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/library_screen.dart' show libraryStoreProvider;
import 'package:flutter_app/screens/root_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_app/views/mini_player_bar.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

EbookFulltext _book() => EbookFulltext.fromJson({
  'jobId': 'layout',
  'bookTitle': 'Layout',
  'chapters': [
    {
      'index': 0,
      'name': 'Capítulo 1',
      'text': List.generate(30, (i) => 'Era o primeiro dia das férias, e ninguém tinha pressa de acordar (${i + 1}).').join('\n\n'),
    },
  ],
});

void main() {
  testWidgets('hiding the chrome does not move or resize the page area', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: InstantReaderView(fulltext: _book())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final area = find.byType(ReaderView);
    expect(find.byIcon(Icons.text_format), findsOneWidget, reason: 'the chrome starts visible');
    final shown = (tester.getTopLeft(area), tester.getSize(area));

    // The centre tap (ReaderView.onCenterTap) toggles the chrome.
    tester.widget<ReaderView>(area).onCenterTap!.call();
    await tester.pumpAndSettle();
    // Hidden (not painted, not interactive) yet still laid out.
    expect(
      find.byWidgetPredicate((w) => w is Visibility && !w.visible && w.maintainSize),
      findsOneWidget,
      reason: 'the centre tap hid the chrome',
    );
    final hidden = (tester.getTopLeft(area), tester.getSize(area));
    expect(hidden, shown, reason: 'the page area keeps its place and size when the bars hide');

    tester.widget<ReaderView>(area).onCenterTap!.call();
    await tester.pumpAndSettle();
    expect((tester.getTopLeft(area), tester.getSize(area)), shown);
  });

  // A8: with the chrome hidden the strip left by the top bar showed the grey
  // scaffold instead of the reader page colour.
  testWidgets('the space of the hidden top bar keeps the reader background', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated', 'readerTheme': 'sepia'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(backgroundColor: const Color(0xFFF2F2F7), body: InstantReaderView(fulltext: _book())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final area = find.byType(ReaderView);
    tester.widget<ReaderView>(area).onCenterTap!.call();
    await tester.pumpAndSettle();

    final hiddenBar = find.byWidgetPredicate((w) => w is Visibility && !w.visible && w.maintainSize);
    expect(hiddenBar, findsOneWidget);
    final strip = tester.getRect(hiddenBar);
    final bg = ReaderThemeColors.background(ReaderTheme.sepia);
    // A painted (not hidden) box in the reader colour must cover the strip.
    final painted = find.byWidgetPredicate((w) => (w is ColoredBox && w.color == bg) || (w is Container && w.color == bg));
    final covering = painted.evaluate().where((e) {
      if (e.findAncestorWidgetOfExactType<Visibility>()?.visible == false) return false;
      final box = e.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      return rect.contains(strip.topLeft) && rect.contains(strip.bottomRight - const Offset(1, 1));
    });
    expect(covering, isNotEmpty, reason: 'the hidden bar strip shows the reader background, not the scaffold grey');
  });

  testWidgets('hiding the chrome keeps the space of the mini player (root shell)', (tester) async {
    SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    // A book that exists in the library (otherwise the reader tab clears itself).
    final book = await tester.runAsync(
      () => container.read(libraryStoreProvider).importBook('../tests/fixtures/epubs/footnote_not_in_toc.epub'),
    );
    container.read(currentlyReadingBookIdProvider.notifier).state = book!.id;
    container.read(appDestinationProvider.notifier).state = AppDestination.reader;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RootScreen(),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    container.read(readerChromeVisibleProvider.notifier).state = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Hidden, but still laid out: the reader area keeps its size.
    final reserved = find.ancestor(
      of: find.byType(MiniPlayerBar, skipOffstage: false),
      matching: find.byWidgetPredicate((w) => w is Visibility && !w.visible && w.maintainSize),
    );
    expect(reserved, findsOneWidget, reason: 'the mini player hides without giving its space to the page');
    final settings = container.read(readerSettingsProvider(book.id));
    final bg = ReaderThemeColors.background(settings.readerTheme, custom: settings.readerCustomColors);
    final strip = find.ancestor(of: reserved, matching: find.byType(ColoredBox)).first;
    expect(tester.widget<ColoredBox>(strip).color, bg, reason: 'the hidden mini player strip shows the reader background');
  });
}
