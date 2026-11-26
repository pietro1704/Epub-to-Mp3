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

/// The speech voice is missing: every chapter conversion fails.
class _NoVoice extends UnavailableEmbeddedConverter {
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
  }) async => throw EmbeddedConversionFailure(
    'RUST_FAILED',
    'system speech error: No installed offline speech voice for pt-BR '
    '[[error_code_v1]]synthesis_failed[[/error_code_v1]]',
  );
}

void main() {
  testWidgets('a failed contents "Download for offline" shows the reason in a snackbar', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory directory;
    await t.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('download-error-');
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
    try {
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            localFulltextCacheProvider.overrideWithValue(_Cache()),
            globalAudioPlayerProvider.overrideWithValue(FakeAudioPlayerService()),
            embeddedConverterProvider.overrideWithValue(_NoVoice()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: BookOpenScreen(bookId: 'dom')),
          ),
        ),
      );
      await t.pumpAndSettle();
      final recent = find.descendant(
        of: find.byKey(const ValueKey('reader-recent-tool')),
        matching: find.byIcon(Icons.list),
      );
      if (recent.evaluate().isNotEmpty) {
        await t.tap(find.byKey(const ValueKey('reader-recent-tool')));
      } else {
        await t.tap(find.byKey(const ValueKey('reader-overflow-menu')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('reader-menu-contents')));
      }
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('contents-download-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Download for offline'));
      for (var i = 0; i < 300 && find.byType(SnackBar).evaluate().isEmpty; i++) {
        await t.pump();
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(find.byType(SnackBar), findsOneWidget, reason: 'the failure is reported');
      expect(find.textContaining('voice'), findsWidgets);
      expect(find.byType(SnackBar), isNotNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
