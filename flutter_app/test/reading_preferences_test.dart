import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/reading_preferences_screen.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<(ProviderContainer, SharedPreferences)> _container({
  Map<String, Object> seed = const {},
}) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return (container, prefs);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  String? bookId,
  Locale? locale,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ReadingPreferencesScreen(bookId: bookId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  largerSizes();
  group('per-book reading overrides', () {
    test(
      'a book without an override reads the default for every book',
      () async {
        final (container, _) = await _container(
          seed: {'readerTheme': 'dark', 'readerFontSize': 4},
        );
        final settings = container.read(readerSettingsProvider('book-a'));
        expect(settings.readerTheme, ReaderTheme.dark);
        expect(settings.readerFontSize, 4);
      },
    );

    test(
      'an override applies only to its book and leaves the default alone',
      () async {
        final (container, prefs) = await _container(
          seed: {'readerTheme': 'dark'},
        );
        await container
            .read(bookReadingOverridesProvider('book-a').notifier)
            .update(
              (o) => o.copyWith(theme: ReaderTheme.sepia, audioRate: 1.5),
            );
        final a = container.read(readerSettingsProvider('book-a'));
        final b = container.read(readerSettingsProvider('book-b'));
        expect(a.readerTheme, ReaderTheme.sepia);
        expect(a.audioRate, 1.5);
        expect(
          b.readerTheme,
          ReaderTheme.dark,
          reason: 'other books keep the default',
        );
        expect(
          AppSettings(prefs).readerTheme,
          ReaderTheme.dark,
          reason: 'the global default is untouched',
        );
      },
    );

    test('Use the default clears the book override', () async {
      final (container, _) = await _container();
      final notifier = container.read(
        bookReadingOverridesProvider('book-a').notifier,
      );
      await notifier.update(
        (o) => o.copyWith(fontSize: 4, layout: ReaderLayout.scrolling),
      );
      expect(
        container.read(readerSettingsProvider('book-a')).readerFontSize,
        4,
      );
      await notifier.clear();
      expect(
        container.read(bookReadingOverridesProvider('book-a')).isEmpty,
        isTrue,
      );
      expect(
        container.read(readerSettingsProvider('book-a')).readerFontSize,
        AppSettings(await SharedPreferences.getInstance()).readerFontSize,
      );
    });

    test('overrides survive a restart (persisted per book)', () async {
      final (container, prefs) = await _container();
      await container
          .read(bookReadingOverridesProvider('book-a').notifier)
          .update((o) => o.copyWith(lineSpacing: 12));
      final again = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(again.dispose);
      expect(
        again.read(readerSettingsProvider('book-a')).readerLineSpacing,
        12,
      );
    });
  });

  group('the single reading preferences screen', () {
    testWidgets(
      'theme and font names use the Apple wording of the app language',
      (tester) async {
        final (container, _) = await _container();
        await _pump(tester, container, locale: const Locale('pt'));
        for (final name in [
          'Claro',
          'Sépia',
          'Pergaminho',
          'Papel',
          'Escuro',
          'Serifada',
          'Sem serifa',
        ]) {
          expect(find.text(name), findsOneWidget, reason: name);
        }
        for (final name in [
          'Light',
          'Parchment',
          'Paper',
          'Dark',
          'Serif',
          'Sans',
        ]) {
          expect(find.text(name), findsNothing, reason: name);
        }
        await _pump(tester, container, locale: const Locale('es'));
        for (final name in ['Claro', 'Pergamino', 'Papel', 'Oscuro']) {
          expect(find.text(name), findsOneWidget, reason: name);
        }
      },
    );

    testWidgets('opened from Settings it edits the default for all books', (
      tester,
    ) async {
      final (container, prefs) = await _container();
      await _pump(tester, container);
      expect(find.text('Default for all books'), findsWidgets);
      expect(
        find.byKey(const ValueKey('reading-mode-book')),
        findsNothing,
        reason: 'no book: no per-book mode',
      );
      await tester.tap(find.byKey(const ValueKey('reading-theme-dark')));
      await tester.pumpAndSettle();
      expect(AppSettings(prefs).readerTheme, ReaderTheme.dark);
    });

    testWidgets(
      'opened from a book the mode is explicit at the top and edits only that book',
      (tester) async {
        final (container, prefs) = await _container();
        await _pump(tester, container, bookId: 'book-a');
        expect(find.byKey(const ValueKey('reading-mode-book')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reading-mode-default')),
          findsOneWidget,
        );
        expect(
          find.text('Only this book'),
          findsWidgets,
          reason: 'a book opens in its own mode (Apple wording)',
        );
        await tester.tap(find.byKey(const ValueKey('reading-theme-sepia')));
        await tester.pumpAndSettle();
        expect(
          container.read(readerSettingsProvider('book-a')).readerTheme,
          ReaderTheme.sepia,
        );
        expect(
          AppSettings(prefs).readerTheme,
          isNot(ReaderTheme.sepia),
          reason: 'the default stays',
        );
      },
    );

    testWidgets('each mode says in Apple wording whom the changes apply to', (
      tester,
    ) async {
      final (container, _) = await _container();
      await _pump(tester, container, bookId: 'book-a');
      expect(
        find.text(
          'Changes apply only to this book. Choose Use the default to go back to the default.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('reading-mode-default')));
      await tester.pumpAndSettle();
      expect(
        find.text('Changes apply to every book without settings of its own.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Use the default clears the override and is hidden when there is none',
      (tester) async {
        final (container, _) = await _container();
        await _pump(tester, container, bookId: 'book-a');
        expect(find.byKey(const ValueKey('reading-use-default')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('reading-theme-sepia')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('reading-use-default')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('reading-use-default')));
        await tester.pumpAndSettle();
        expect(
          container.read(bookReadingOverridesProvider('book-a')).isEmpty,
          isTrue,
        );
      },
    );

    testWidgets(
      'the book switch turned off stays off when the panel is opened again',
      (tester) async {
        final (container, prefs) = await _container();
        await _pump(tester, container, bookId: 'book-a');
        await tester.tap(find.byKey(const ValueKey('reading-mode-default')));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        final (reopened, _) = await _container(
          seed: {for (final k in prefs.getKeys()) k: prefs.get(k)!},
        );
        await _pump(tester, reopened, bookId: 'book-a');
        await tester.tap(find.byKey(const ValueKey('reading-theme-dark')));
        await tester.pumpAndSettle();
        expect(
          reopened.read(bookReadingOverridesProvider('book-a')).isEmpty,
          isTrue,
          reason: 'still editing the default',
        );
      },
    );

    testWidgets(
      'switching the mode to default edits the default even from a book',
      (tester) async {
        final (container, prefs) = await _container();
        await _pump(tester, container, bookId: 'book-a');
        await tester.tap(find.byKey(const ValueKey('reading-mode-default')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reading-theme-dark')));
        await tester.pumpAndSettle();
        expect(AppSettings(prefs).readerTheme, ReaderTheme.dark);
        expect(
          container.read(bookReadingOverridesProvider('book-a')).isEmpty,
          isTrue,
        );
      },
    );
  });

  testWidgets(
    'the appearance panel carries the follow-audio switch, a global setting even when opened from a book',
    (tester) async {
      final (container, prefs) = await _container();
      await _pump(tester, container, bookId: 'book-1');
      final toggle = find.byKey(const ValueKey('reader-follow-audio'));
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(prefs.getBool('readerAutoScroll'), isFalse);
    },
  );

  testWidgets('the reader Aa opens the screen for that book, in its own mode', (
    tester,
  ) async {
    final (container, _) = await _container();
    final book = EbookFulltext.fromJson({
      'jobId': 'aa',
      'chapters': [
        {'index': 0, 'name': 'One', 'text': 'Era o primeiro dia das férias.'},
      ],
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: InstantReaderView(fulltext: book, bookId: 'book-a'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.text_format));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-mode-book')), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('reading-mode-book')),
    );
    expect(
      chip.selected,
      isTrue,
      reason: 'from a book the screen opens in its own mode',
    );
  });
}

void largerSizes() {
  testWidgets(
    'the size control reaches the larger steps and stops at the last',
    (tester) async {
      final (container, _) = await _container(seed: {'readerFontSize': 4});
      await _pump(tester, container);
      final more = find.byIcon(Icons.text_increase);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('32 pt'), findsOneWidget);
      for (final pt in ['36', '42', '48']) {
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text('$pt pt'), findsOneWidget);
      }
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.text_increase),
            )
            .onPressed,
        isNull,
      );
      expect(container.read(settingsProvider).readerFontSize, 8);
    },
  );
}
