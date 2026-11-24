import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/book_language_corrections.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/book_open_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/storage/local_fulltext_cache.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player_service.dart';

class _Cache extends LocalFulltextCache {
  _Cache() : super(directoryProvider: () async => throw StateError('unused'));
  final Map<String, EbookFulltext> _store = {};
  @override
  Future<EbookFulltext?> read(String bookId) async => _store[bookId];
  @override
  Future<void> save(EbookFulltext payload, String bookId) async =>
      _store[bookId] = payload;
  @override
  Future<void> evict(String bookId) async => _store.remove(bookId);
}

/// Rust cannot tell the language of the first passage until the user says so.
class _UncertainThenFine extends UnavailableEmbeddedConverter {
  final List<String?> options = [];
  @override
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) async =>
      EbookFulltext.fromJson({
        'jobId': jobId,
        'bookTitle': 'Dom Casmurro',
        'chapters': [
          {'index': 0, 'name': 'Capitulo 0', 'text': 'Texto de um livro.'},
        ],
      });

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    options.add(optionsJson);
    final decoded = jsonDecode(optionsJson!) as Map;
    if (decoded['language_overrides'] == null) {
      throw EmbeddedConversionFailure(
        'RUST_FAILED',
        '[[book_language_uncertain_v1]]{"chapter_index":0,"start":0,"end":12}'
        '[[/book_language_uncertain_v1]]',
      );
    }
    final directory = Directory(outputPath);
    await directory.create(recursive: true);
    final audio = File('${directory.path}/chapter.mp3');
    await audio.writeAsBytes([0x49, 0x44, 0x33, 1]);
    return ConvertedChapterAudio(
      chapterIndex: chapterIndex,
      path: audio.path,
      title: 'Capitulo 0',
    );
  }
}

void main() {
  testWidgets(
    'an undetectable language asks the user, remembers the answer and converts again with it',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      late Directory directory;
      await t.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('language-recovery-');
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => directory.path);
      final book = BookEntity(
        id: 'dom',
        title: 'Dom Casmurro',
        filePath: '/tmp/dom.epub',
        displayFilename: 'dom.epub',
        addedAt: DateTime(2025),
      );
      SharedPreferences.setMockInitialValues({'library.books.v1': '[${book.encode()}]'});
      final prefs = await SharedPreferences.getInstance();
      final converter = _UncertainThenFine();
      final player = FakeAudioPlayerService();
      try {
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              localFulltextCacheProvider.overrideWithValue(_Cache()),
              globalAudioPlayerProvider.overrideWithValue(player),
              embeddedConverterProvider.overrideWithValue(converter),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: BookOpenScreen(bookId: 'dom')),
            ),
          ),
        );
        await t.pumpAndSettle();
        final container = ProviderScope.containerOf(t.element(find.byType(BookOpenScreen)));
        final listen = container.read(playbackRequestProvider)!;
        Future<void>? pending;
        await t.runAsync(() async {
          pending = listen();
        });
        for (var i = 0; i < 300 && find.text('Book language').evaluate().isEmpty; i++) {
          await t.pump();
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        }
        expect(find.text('Book language'), findsOneWidget, reason: 'the user is asked');
        expect(
          find.textContaining('could not be identified'),
          findsOneWidget,
          reason: 'with the inconclusive explanation',
        );
        expect(find.text('Automatic detection'), findsNothing, reason: 'a choice is required here');
        await t.scrollUntilVisible(
          find.text('Português (Brasil)'),
          200,
          scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)),
        );
        await t.tap(find.text('Português (Brasil)'));
        await t.pump();
        await t.runAsync(() async => await pending);
        await t.pumpAndSettle();

        expect(converter.options, hasLength(2), reason: 'converted again after the answer');
        final retry = jsonDecode(converter.options.last!) as Map;
        expect(retry['language_overrides'], [
          {'chapter_index': 0, 'start': 0, 'end': 12, 'language': 'pt-BR'},
        ]);
        expect(
          BookLanguageCorrections(prefs).decision('dom').passages.single.language,
          'pt-BR',
          reason: 'remembered for the next time',
        );
        expect(player.hasQueuedAudio, true);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await t.runAsync(() async => directory.delete(recursive: true));
      }
    },
  );
}
