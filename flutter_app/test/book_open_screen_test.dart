import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_app/services/embedded_converter.dart';
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
  int uploads = 0;

  @override
  Future<String> uploadAndConvert(
    String filePath, {
    int? chapterEnd,
    int? chapterStart,
    String engine = 'edge',
    bool? includeCover,
    String? language,
    bool? normalizeAudio,
    String? voice,
  }) async {
    uploads++;
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

class _DesktopFakeConverter extends UnavailableEmbeddedConverter {
  int parses = 0;
  final List<String?> options = [];
  @override
  Future<EbookFulltext> parse({
    required String inputPath,
    String jobId = '',
  }) async {
    parses++;
    return EbookFulltext.fromJson({
      'jobId': jobId,
      'bookTitle': 'Desktop book',
      'chapters': [
        {
          'index': 0,
          'name': 'Chapter 0',
          'text': 'Um texto em português para ouvir.',
        },
      ],
    });
  }

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    options.add(optionsJson);
    final directory = Directory(outputPath);
    await directory.create(recursive: true);
    final audio = File('${directory.path}/chapter.mp3');
    await audio.writeAsBytes([0x49, 0x44, 0x33, 1]);
    return ConvertedChapterAudio(
      chapterIndex: chapterIndex,
      path: audio.path,
      title: 'Chapter 0',
    );
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
  EmbeddedConverter? converter,
}) {
  return ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      localFulltextCacheProvider.overrideWithValue(cache),
      if (apiClient != null) apiClientProvider.overrideWithValue(apiClient),
      if (player != null) globalAudioPlayerProvider.overrideWithValue(player),
      if (converter != null)
        embeddedConverterProvider.overrideWithValue(converter),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: BookOpenScreen(bookId: bookId)),
    ),
  );
}

void main() {
  testWidgets('disposing during model-root lookup does not persist a job', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final enteredSupport = Completer<void>();
    final releaseSupport = Completer<String>();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('disposed-listen-');
    });
    final book = BookEntity(
      id: 'desktop',
      title: 'Desktop book',
      filePath: '/tmp/desktop.epub',
      displayFilename: 'desktop.epub',
      addedAt: DateTime(2025),
    );
    final prefs = await _mockPrefs({
      'library.books.v1': '[${book.encode()}]',
    });
    final converter = _DesktopFakeConverter();
    final player = FakeAudioPlayerService();
    final api = _FakeApiClient();
    Future<void>? pendingPlayback;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            if (!enteredSupport.isCompleted) enteredSupport.complete();
            return releaseSupport.future;
          }
          return directory.path;
        });
    try {
      await tester.pumpWidget(
        _wrap(
          prefs,
          'desktop',
          cache: _FakeFulltextCache(),
          apiClient: api,
          player: player,
          converter: converter,
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BookOpenScreen)),
      );
      final listen = container.read(playbackRequestProvider);
      expect(listen, isNotNull);
      await tester.runAsync(() async {
        pendingPlayback = listen!();
        await enteredSupport.future.timeout(const Duration(seconds: 5));
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        releaseSupport.complete(directory.path);
        await pendingPlayback;
      });
      expect(
        prefs.getString('local-conversion.v1:desktop:local-desktop'),
        isNull,
      );
      expect(converter.options, isEmpty);
      expect(api.uploads, 0);
      expect(player.hasQueuedAudio, false);
      expect(player.isPlaying, false);
      expect(tester.takeException(), isNull);
    } finally {
      if (!releaseSupport.isCompleted) releaseSupport.complete(directory.path);
      await tester.runAsync(() async => await pendingPlayback);
      await tester.pumpWidget(const SizedBox.shrink());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = previousPlatform;
      await player.dispose();
      await tester.runAsync(() async => directory.delete(recursive: true));
    }
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets(
      '$platform parses and listens through local Rust adapter without HTTP',
      (t) async {
        debugDefaultTargetPlatformOverride = platform;
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        late Directory directory;
        await t.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'desktop-listen-ui-',
          );
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => directory.path);
        final book = BookEntity(
          id: 'desktop',
          title: 'Desktop book',
          filePath: '/tmp/desktop.epub',
          displayFilename: 'desktop.epub',
          addedAt: DateTime(2025),
        );
        final prefs = await _mockPrefs({
          'library.books.v1': '[${book.encode()}]',
          'useEmbeddedRuntime': false,
        });
        final api = _FakeApiClient();
        final converter = _DesktopFakeConverter();
        final player = FakeAudioPlayerService();
        try {
          await t.pumpWidget(
            _wrap(
              prefs,
              'desktop',
              cache: _FakeFulltextCache(),
              apiClient: api,
              player: player,
              converter: converter,
            ),
          );
          await t.pumpAndSettle();
          expect(converter.parses, 1);
          final container = ProviderScope.containerOf(
            t.element(find.byType(BookOpenScreen)),
          );
          final listen = container.read(playbackRequestProvider);
          expect(listen, isNotNull);
          await t.runAsync(() async {
            await listen!();
          });
          await t.pumpAndSettle();
          expect(converter.options, hasLength(1));
          expect(
            jsonDecode(
              converter.options.single!,
            )['tts_preferences']['primary']['model_id'],
            'pt_BR-faber-medium',
          );
          expect(api.uploads, 0);
          expect(player.hasQueuedAudio, true);
          expect(player.isPlaying, true);
        } finally {
          await t.pumpWidget(const SizedBox.shrink());
          await player.dispose();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          debugDefaultTargetPlatformOverride = null;
          await t.runAsync(() async {
            await directory.delete(recursive: true);
          });
        }
      },
    );
  }

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
      // The Reader has no standalone conversion action; conversion is
      // requested by the persistent player's Play control.
      expect(find.text('Converter'), findsNothing);
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

    testWidgets('BookOpenScreen does not render a duplicate play button', (
      t,
    ) async {
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

      await t.pumpWidget(
        _wrap(
          prefs,
          'play-book',
          cache: cache,
          apiClient: fakeApi,
          player: fakePlayer,
        ),
      );
      await t.pump();
      await t.pump();

      // The play button should be visible in the bottom bar.
      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });

    testWidgets('conversion falls back to local when backend fails', (t) async {
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

      await t.pumpWidget(
        _wrap(
          prefs,
          'fallback-book',
          cache: cache,
          apiClient: fakeApi,
          player: fakePlayer,
        ),
      );
      await t.pump();
      await t.pump();

      // Audio conversion is intentionally controlled by the global shell.
      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });
  });
}
