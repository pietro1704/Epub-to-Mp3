import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/book_open_screen.dart';
import 'package:flutter_app/services/local_fulltext_cache.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory cache that avoids real file I/O in tests.
class _FakeFulltextCache extends LocalFulltextCache {
  _FakeFulltextCache() : super(directoryProvider: _neverCalled);

  static Future<Never> _neverCalled() async =>
      throw StateError('should not be called');

  final Map<String, EbookFulltext> _store = {};

  @override
  Future<EbookFulltext?> read(String bookId) async => _store[bookId];

  @override
  Future<void> save(EbookFulltext payload, String bookId) async {
    _store[bookId] = payload;
  }

  @override
  Future<void> evict(String bookId) async {
    _store.remove(bookId);
  }
}

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, String bookId,
    {required LocalFulltextCache cache}) {
  return ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      localFulltextCacheProvider.overrideWithValue(cache),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: BookOpenScreen(bookId: bookId)),
    ),
  );
}

void main() {
  group('BookOpenScreen', () {
    testWidgets('shows reader when cached fulltext exists', (t) async {
      final book = BookEntity(
        id: 'cached-book',
        title: 'Cached Book',
        author: 'Author',
        filePath: '/tmp/cached.epub',
        displayFilename: 'cached.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final booksJson = '[${book.encode()}]';
      final prefs = await _mockPrefs({'library.books.v1': booksJson});

      final cache = _FakeFulltextCache();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'cached-book',
        'bookTitle': 'Cached Book',
        'bookAuthor': 'Author',
        'chapters': [
          {
            'index': 0,
            'name': 'Chapter 1',
            'text':
                'This is the content of chapter one with enough text to be displayed properly.',
          },
        ],
      });
      cache._store['cached-book'] = fulltext;

      await t.pumpWidget(_wrap(prefs, 'cached-book', cache: cache));
      // Multiple pumps to drain microtask queue from the async _load().
      await t.pump();
      await t.pump();

      // Should show reader content (chapter title from InstantReaderView).
      expect(find.text('Chapter 1'), findsWidgets);
    });

    testWidgets('shows error when parsing unavailable', (t) async {
      final prefs = await _mockPrefs();
      final cache = _FakeFulltextCache();

      await t.pumpWidget(_wrap(prefs, 'missing-book', cache: cache));
      // Let the async _load complete (cache miss => isSupported=false).
      await t.pump();
      await t.pump();

      // PythonBridge.isSupported is false on macOS test host, so the
      // error state should render.
      expect(find.text('Could not open this book'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
