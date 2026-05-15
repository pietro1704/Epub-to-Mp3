import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/reader_tab.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ReaderTab()),
    ),
  );
}

void main() {
  group('ReaderTab', () {
    testWidgets('shows empty state when no book selected', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      expect(find.text('Pick a book to read'), findsOneWidget);
      expect(find.text('Browse Library'), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
    });

    testWidgets('shows empty state when bookId set but book not in library',
        (t) async {
      final prefs = await _mockPrefs({
        'currentlyReadingBookId': 'nonexistent-id',
      });
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      // Should auto-clear and show empty state.
      expect(find.text('Pick a book to read'), findsOneWidget);
    });

    testWidgets('browse library button sets tab index to 1', (t) async {
      final prefs = await _mockPrefs();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: ReaderTab()),
          ),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.text('Browse Library'));
      await t.pump();

      expect(container.read(rootTabIndexProvider), 1);
      container.dispose();
    });

    testWidgets('shows BookOpenScreen when book is in library', (t) async {
      final book = BookEntity(
        id: 'abc123',
        title: 'My Book',
        author: 'Author',
        filePath: '/tmp/test.epub',
        displayFilename: 'test.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final booksJson = '[${book.encode()}]';
      final prefs = await _mockPrefs({
        'currentlyReadingBookId': 'abc123',
        'library.books.v1': booksJson,
      });
      await t.pumpWidget(_wrap(prefs));
      await t.pump();

      // BookOpenScreen should show (at least a loading/parsing state).
      // Since PythonBridge is not available in test, we should see an error
      // or loading state — but NOT the empty reader state.
      expect(find.text('Pick a book to read'), findsNothing);
    });
  });
}
