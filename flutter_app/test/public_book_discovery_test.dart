import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/features/library/public_book_catalog.dart';
import 'package:flutter_app/features/library/public_book_discovery_sheet.dart';
import 'package:flutter_app/features/library/public_book_download.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  test('filters title and author and prioritizes the local language', () {
    final all = searchPublicBooks('', 'pt');
    expect(all.first.language, 'pt');
    expect(all.any((book) => book.language == 'en'), isTrue);
    final matches = searchPublicBooks('Papeis Machado', 'en');
    expect(matches.single.title, 'Papéis Avulsos');
    expect(matches.single.source, 'Project Gutenberg');
  });

  test('selects EPUB when offered and PDF for PDF-only editions', () {
    final camara = searchPublicBooks('dom casmurro', 'pt').single;
    expect(camara.source, 'Edições Câmara');
    expect(
      camara.sourcePage,
      'https://livraria.camara.leg.br/produto/dom-casmurro/',
    );
    expect(camara.format, PublicBookFormat.epub);
    expect(
      camara.downloadUri,
      Uri.https(
        'bd-rest.camara.leg.br',
        '/server/api/core/bitstreams/2b30f5a5-5e5f-49fd-9db7-f4a6c31c457f/content',
      ),
    );
    expect(
      Uri.parse(camara.pdf!),
      Uri.https(
        'bd-rest.camara.leg.br',
        '/server/api/core/bitstreams/8835c1ee-9566-4465-bc91-ce7003a6d4de/content',
      ),
    );
    const pdfOnly = PublicBook(
      title: 'Public PDF',
      author: 'Author',
      language: 'en',
      source: 'Source',
      pdf: 'https://bd-rest.camara.leg.br/public.pdf',
    );
    expect(pdfOnly.format, PublicBookFormat.pdf);
  });

  test('Gutenberg downloads use the official mirror and keep public pages', () {
    const editions = {
      '11': 'pg11-images-3.epub',
      '1342': 'pg1342.epub',
      '76': 'pg76.epub',
      '57001': 'pg57001-images-3.epub',
    };
    final books = searchPublicBooks(
      '',
      'en',
    ).where((book) => book.source == 'Project Gutenberg');
    expect(books, hasLength(editions.length));
    for (final edition in editions.entries) {
      final book = books.singleWhere(
        (book) =>
            book.sourcePage ==
            'https://www.gutenberg.org/ebooks/${edition.key}',
      );
      expect(
        book.downloadUri,
        Uri.https(
          'gutenberg.pglaf.org',
          '/cache/epub/${edition.key}/${edition.value}',
        ),
      );
    }
  });

  testWidgets('publisher attribution opens the official book page', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var canOpen = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return canOpen;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: PublicBookDiscoverySheet(
            onPickFile: () {},
            onDownload: (_) =>
                throw StateError('Source link started a download'),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'dom casmurro');
    await tester.pumpAndSettle();
    final source = find.widgetWithText(TextButton, 'Edições Câmara');
    expect(source, findsOneWidget);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(calls.single.method, 'launch');
    expect(
      calls.single.arguments['url'],
      'https://livraria.camara.leg.br/produto/dom-casmurro/',
    );
    expect(find.text('Could not open the publisher’s page.'), findsOneWidget);

    canOpen = true;
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(find.text('Could not open the publisher’s page.'), findsNothing);
  });

  testWidgets('Library Add a book exposes both local import and search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: _app(const LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add a book'));
    await tester.pumpAndSettle();
    expect(find.text('Import an EPUB or PDF file'), findsOneWidget);
    expect(find.text('Search classic books'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'jane austen');
    await tester.pumpAndSettle();
    expect(find.text('Pride and Prejudice'), findsOneWidget);
    expect(find.text('Jane Austen'), findsOneWidget);
    expect(
      find.widgetWithText(TextButton, 'Project Gutenberg'),
      findsOneWidget,
    );
    expect(find.text('Dom Casmurro'), findsNothing);
  });

  testWidgets('failed download leaves the result available for retry', (
    tester,
  ) async {
    var transfer = Completer<BookEntity>();
    BookEntity? result;
    var requests = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<BookEntity>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PublicBookDiscoverySheet(
                    onPickFile: () {},
                    onDownload: (book) {
                      expect(book.title, 'Pride and Prejudice');
                      requests++;
                      return transfer.future;
                    },
                  ),
                );
              },
              child: const Text('Open discovery'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open discovery'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'austen');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pride and Prejudice'));
    await tester.pumpAndSettle();
    expect(find.text('Downloading…'), findsOneWidget);
    expect(requests, 1);
    transfer.completeError(Exception('Network unavailable'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not download or import this book. Try again.'),
      findsOneWidget,
    );
    expect(result, isNull);

    transfer = Completer<BookEntity>();
    await tester.tap(find.text('Pride and Prejudice'));
    await tester.pumpAndSettle();
    final imported = BookEntity(
      id: 'fixture-book',
      title: 'Pride and Prejudice',
      filePath: '/fixture-book.epub',
      displayFilename: 'Pride and Prejudice.epub',
      addedAt: DateTime(2026),
    );
    transfer.complete(imported);
    await tester.pumpAndSettle();
    expect(result, same(imported));
    expect(requests, 2);
    expect(find.byType(PublicBookDiscoverySheet), findsNothing);
  });
}
