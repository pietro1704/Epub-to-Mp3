import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore_for_file: unused_import

/// Build the app with a real SharedPreferences to avoid async issues.
Future<void> _pumpLibrary(
  WidgetTester tester, {
  Map<String, Object> prefsData = const {},
  Locale locale = const Locale('en'),
}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('library grid keeps two columns across phone and wide resize', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final books = List.generate(
      4,
      (i) => BookEntity(
        id: 'grid-$i',
        title: 'Book $i with a long title that wraps onto multiple lines',
        author: 'An author with a long name that needs truncation',
        filePath: '/tmp/grid-$i.epub',
        displayFilename: 'grid-$i.epub',
        addedAt: DateTime(2025, 1, 4 - i),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(320, 1200));
    await _pumpLibrary(
      tester,
      prefsData: {
        'library.books.v1': '[${books.map((book) => book.encode()).join(',')}]',
      },
    );

    for (final width in [320.0, 390.0, 768.0, 1440.0, 320.0]) {
      await tester.binding.setSurfaceSize(Size(width, 2400));
      await tester.pumpAndSettle();

      final cards = find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Card),
      );
      expect(cards, findsNWidgets(4));
      final rects = List.generate(4, (i) => tester.getRect(cards.at(i)));
      expect(rects[0].top, closeTo(rects[1].top, 0.01));
      expect(rects[2].top, closeTo(rects[3].top, 0.01));
      expect(rects[2].top, greaterThan(rects[0].bottom));
      expect(rects[0].left, closeTo(rects[2].left, 0.01));
      expect(rects[1].left, closeTo(rects[3].left, 0.01));
      expect(rects[1].left, greaterThan(rects[0].right));
      expect(rects[0].width, closeTo(rects[1].width, 0.01));
      expect(rects[0].left, greaterThanOrEqualTo(0));
      expect(rects[1].right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('empty library shows add-book prompt', (tester) async {
    await _pumpLibrary(tester);

    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.text('Add a book'), findsOneWidget);
  });

  testWidgets('library with persisted books renders grid cards', (
    tester,
  ) async {
    final book = BookEntity(
      id: 'abc123',
      title: 'Test Book',
      author: 'Author A',
      filePath: '/tmp/test.epub',
      displayFilename: 'test.epub',
      addedAt: DateTime(2025, 1, 1),
    );
    final json = '[${book.encode()}]';

    await _pumpLibrary(tester, prefsData: {'library.books.v1': json});

    expect(find.text('Test Book'), findsOneWidget);
    expect(find.text('Author A'), findsOneWidget);
  });

  testWidgets('sort button visible in app bar', (tester) async {
    final book = BookEntity(
      id: 'abc123',
      title: 'Test Book',
      author: 'Author',
      filePath: '/tmp/test.epub',
      displayFilename: 'test.epub',
      addedAt: DateTime(2025, 1, 1),
    );
    await _pumpLibrary(
      tester,
      prefsData: {'library.books.v1': '[${book.encode()}]'},
    );

    expect(find.byIcon(Icons.sort), findsOneWidget);
  });

  testWidgets('sort menu shows three options', (tester) async {
    final book = BookEntity(
      id: 'abc123',
      title: 'Test Book',
      author: 'Author',
      filePath: '/tmp/test.epub',
      displayFilename: 'test.epub',
      addedAt: DateTime(2025, 1, 1),
    );
    await _pumpLibrary(
      tester,
      prefsData: {'library.books.v1': '[${book.encode()}]'},
    );

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();

    expect(find.text('Last opened'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Date added'), findsOneWidget);
  });

  testWidgets('empty library shows description text', (tester) async {
    await _pumpLibrary(tester);

    expect(
      find.text(
        'Tap + to import an EPUB or PDF, or share one from another app.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('long press on book card shows actions sheet', (tester) async {
    final book = BookEntity(
      id: 'abc123',
      title: 'My EPUB',
      author: null,
      filePath: '/tmp/my.epub',
      displayFilename: 'my.epub',
      addedAt: DateTime(2025, 6, 1),
    );
    final json = '[${book.encode()}]';

    await _pumpLibrary(tester, prefsData: {'library.books.v1': json});

    final title = find.text('My EPUB');
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(title.hitTestable(), findsOneWidget);
    await tester.longPress(title);
    await tester.pumpAndSettle();

    // Bottom sheet with Edit Tags + Remove from library
    expect(find.text('Edit Tags'), findsOneWidget);
    expect(find.text('Remove from library'), findsOneWidget);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
        'visible book actions open and dismiss tag editor in ${locale.languageCode}',
        (tester) async {
      final book = BookEntity(
        id: 'tag-book',
        title: 'Selected EPUB',
        author: 'Author',
        filePath: '/tmp/selected.epub',
        displayFilename: 'selected.epub',
        addedAt: DateTime(2025, 6, 1),
        tags: ['Original'],
      );
      final untouchedBook = BookEntity(
        id: 'other-book',
        title: 'Another EPUB',
        filePath: '/tmp/other.epub',
        displayFilename: 'other.epub',
        addedAt: DateTime(2025, 5, 1),
        tags: ['Other'],
      );
      await _pumpLibrary(tester, locale: locale, prefsData: {
        'library.books.v1': '[${book.encode()},${untouchedBook.encode()}]',
      });
      final context = tester.element(find.byType(LibraryScreen));
      final labels = AppLocalizations.of(context)!;
      final container = ProviderScope.containerOf(context);
      final store = container.read(libraryStoreProvider);
      final before = store.books.map((item) => item.encode()).toList();

      Future<void> openActions() async {
        final title = find.text(book.title);
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        expect(title.hitTestable(), findsOneWidget);
        await tester.longPress(title);
        await tester.pumpAndSettle();
        expect(find.text(labels.editTags), findsOneWidget);
        expect(find.text(labels.removeFromLibrary), findsOneWidget);
      }

      await openActions();
      // Dismissing the action sheet must not open the reader or change books.
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.text(labels.editTags), findsNothing);
      expect(container.read(currentlyReadingBookIdProvider), isNull);

      await openActions();
      await tester.tap(find.text(labels.editTags));
      await tester.pumpAndSettle();
      final editor = find.byType(DraggableScrollableSheet);
      expect(editor, findsOneWidget);
      expect(find.descendant(of: editor, matching: find.text('Original')),
          findsOneWidget);
      expect(find.descendant(of: editor, matching: find.text('Other')),
          findsOneWidget);
      await tester.enterText(
        find.descendant(of: editor, matching: find.byType(TextField)),
        'Unsaved tag',
      );
      await tester.tap(find.text(labels.done));
      await tester.pumpAndSettle();

      expect(editor, findsNothing);
      expect(store.books.map((item) => item.encode()).toList(), equals(before));
      expect(container.read(currentlyReadingBookIdProvider), isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
