import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/screens/book_open_screen.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/local_fulltext_cache.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake API client that always throws on upload — simulates unreachable
/// backend so the conversion flow falls through to PythonBridge.
class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super('http://fake');

  @override
  Future<String> uploadAndConvert(String filePath) async {
    throw Exception('Backend unreachable');
  }

  @override
  Stream<JobSnapshot> jobStream(String jobId) => const Stream.empty();

  @override
  Future<List<int>?> fetchBytes(String url) async => null;
}

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

Widget _wrap(
  SharedPreferences prefs,
  String bookId, {
  required LocalFulltextCache cache,
  ApiClient? apiClient,
  AudioPlayerInterface? player,
}) {
  return ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      localFulltextCacheProvider.overrideWithValue(cache),
      if (apiClient != null)
        apiClientProvider.overrideWithValue(apiClient),
      if (player != null)
        globalAudioPlayerProvider.overrideWithValue(player),
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

    testWidgets('play button visible in bottom bar when ready', (t) async {
      final book = BookEntity(
        id: 'play-book',
        title: 'Play Book',
        author: 'Author',
        filePath: '/tmp/play.epub',
        displayFilename: 'play.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final booksJson = '[${book.encode()}]';
      final prefs = await _mockPrefs({'library.books.v1': booksJson});

      final cache = _FakeFulltextCache();
      cache._store['play-book'] = EbookFulltext.fromJson({
        'jobId': 'play-book',
        'bookTitle': 'Play Book',
        'bookAuthor': 'Author',
        'chapters': [
          {
            'index': 0,
            'name': 'Chapter 1',
            'text': 'Enough text to be displayed properly in the reader view.',
          },
        ],
      });

      final fakeApi = _FakeApiClient();
      final fakePlayer = FakeAudioPlayerService();

      await t.pumpWidget(_wrap(
        prefs,
        'play-book',
        cache: cache,
        apiClient: fakeApi,
        player: fakePlayer,
      ));
      await t.pump();
      await t.pump();

      // The play button should be visible in the bottom bar.
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
    });

    testWidgets('conversion falls back to local when backend fails',
        (t) async {
      final book = BookEntity(
        id: 'fallback-book',
        title: 'Fallback Book',
        filePath: '/tmp/fallback.epub',
        displayFilename: 'fallback.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final booksJson = '[${book.encode()}]';
      final prefs = await _mockPrefs({'library.books.v1': booksJson});

      final cache = _FakeFulltextCache();
      cache._store['fallback-book'] = EbookFulltext.fromJson({
        'jobId': 'fallback-book',
        'bookTitle': 'Fallback Book',
        'chapters': [
          {
            'index': 0,
            'name': 'Ch 1',
            'text': 'Some text content for conversion testing.',
          },
        ],
      });

      final fakeApi = _FakeApiClient();
      final fakePlayer = FakeAudioPlayerService();

      await t.pumpWidget(_wrap(
        prefs,
        'fallback-book',
        cache: cache,
        apiClient: fakeApi,
        player: fakePlayer,
      ));
      await t.pump();
      await t.pump();

      // Tap play button to trigger conversion
      await t.tap(find.byIcon(Icons.play_circle_filled));
      await t.pump();
      await t.pump();
      await t.pump();

      // Backend throws → PythonBridge not supported on macOS test host →
      // error banner appears in the bottom bar with a warning icon.
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });
}
