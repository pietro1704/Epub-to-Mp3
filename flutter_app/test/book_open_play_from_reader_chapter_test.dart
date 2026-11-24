import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
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
  Future<void> save(EbookFulltext payload, String bookId) async => _store[bookId] = payload;
  @override
  Future<void> evict(String bookId) async => _store.remove(bookId);
}

/// Like the Android converter: it cannot start inside a chapter (not a PositionedChapterConverter).
class _ChapterRecordingConverter extends UnavailableEmbeddedConverter {
  final converted = <int>[];
  @override
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) async =>
      EbookFulltext.fromJson({
        'jobId': jobId,
        'bookTitle': 'The Lord of the Rings',
        'chapters': [
          for (var i = 0; i < 4; i++) {'index': i, 'name': 'Chapter $i', 'text': 'Text of chapter $i. ' * 20},
        ],
      });

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    converted.add(chapterIndex);
    final directory = Directory(outputPath);
    await directory.create(recursive: true);
    final audio = File('${directory.path}/chapter.mp3');
    await audio.writeAsBytes([0x49, 0x44, 0x33, 1]);
    return ConvertedChapterAudio(chapterIndex: chapterIndex, path: audio.path, title: 'Chapter $chapterIndex');
  }
}

void main() {
  testWidgets(
    'Play converts the chapter the reader shows, not the chapter saved from the last listening (A8: Many Meetings started at the epigraph)',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      late Directory directory;
      await t.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('play-reader-chapter-');
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => directory.path);
      final book = BookEntity(
        id: 'lotr',
        title: 'The Lord of the Rings',
        filePath: '/tmp/lotr.epub',
        displayFilename: 'lotr.epub',
        addedAt: DateTime(2025),
      );
      SharedPreferences.setMockInitialValues({
        'library.books.v1': '[${book.encode()}]',
        // Last listening ended in chapter 0 (the epigraph) ...
        'resume:book:lotr:chapter': 0,
        'resume:book:lotr:position': 3.0,
        // ... but the reader is now on chapter 2 ("Many Meetings").
        'readPos_ch_lotr': 2,
      });
      final prefs = await SharedPreferences.getInstance();
      final converter = _ChapterRecordingConverter();
      final player = FakeAudioPlayerService();
      Future<void>? pending;
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
              home: const Scaffold(body: BookOpenScreen(bookId: 'lotr')),
            ),
          ),
        );
        await t.pumpAndSettle();
        final container = ProviderScope.containerOf(t.element(find.byType(BookOpenScreen)));
        final listen = container.read(playbackRequestProvider)!;
        await t.runAsync(() async {
          pending = listen();
        });
        for (var i = 0; i < 200 && converter.converted.isEmpty; i++) {
          await t.pump();
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        }
        expect(converter.converted, isNotEmpty);
        expect(converter.converted.first, 2, reason: 'the first synthesized chapter is the one the reader shows');
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await t.runAsync(() async {
          await pending?.timeout(const Duration(seconds: 5), onTimeout: () {});
        });
        await player.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await t.runAsync(() async => directory.delete(recursive: true));
      }
    },
  );
}
