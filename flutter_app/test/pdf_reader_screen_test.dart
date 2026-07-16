import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/book_open_screen.dart';
import 'package:flutter_app/screens/pdf_reader_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PDF reader routing', () {
    test('recognizes PDF extension case-insensitively', () {
      expect(isPdfFilePath('/books/novel.PDF'), isTrue);
      expect(isPdfFilePath('/books/novel.epub'), isFalse);
    });

    test('persists page independently by book id', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PdfPageStore(prefs);

      await store.savePage('book-a', 7);
      await store.savePage('book-b', 2);

      expect(store.loadPage('book-a'), 7);
      expect(store.loadPage('book-b'), 2);
      expect(store.loadPage('book-c'), 1);
    });

    testWidgets('PDF reader accepts initial file and renders injected viewer', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        MaterialApp(
          home: PdfReaderScreen(
            bookId: 'book-a',
            title: 'A PDF',
            filePath: '/tmp/initial.pdf',
            prefs: prefs,
            loadDocument: () async {},
            viewerBuilder: (context, path, initialPage, onPageChanged) =>
                Text('viewer:$path:$initialPage'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('viewer:/tmp/initial.pdf:1'), findsOneWidget);
      expect(find.text('A PDF'), findsOneWidget);
    });

    testWidgets('PDF reader shows loading then error from injected loader', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final loading = find.byKey(const Key('pdf-reader-loading'));

      await tester.pumpWidget(
        MaterialApp(
          home: PdfReaderScreen(
            bookId: 'broken',
            title: 'Broken PDF',
            filePath: '/tmp/broken.pdf',
            prefs: prefs,
            loadDocument: () async => throw StateError('cannot open PDF'),
          ),
        ),
      );
      expect(loading, findsOneWidget);
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot open PDF'), findsOneWidget);
    });

    testWidgets('BookOpenScreen routes a PDF to PdfReaderScreen', (
      tester,
    ) async {
      final book = TestBookFixture.pdfBook();
      SharedPreferences.setMockInitialValues({
        'library.books.v1': '[${book.encode()}]',
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const BookOpenScreen(bookId: 'pdf-book'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(PdfReaderScreen), findsOneWidget);
      expect(find.text('PDF Book'), findsOneWidget);
    });
  });
}

class TestBookFixture {
  static dynamic pdfBook() => BookEntity(
    id: 'pdf-book',
    title: 'PDF Book',
    filePath: '/tmp/book.pdf',
    displayFilename: 'book.pdf',
    addedAt: DateTime(2025, 1, 1),
  );
}
