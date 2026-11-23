import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_narration_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts every call that would reach Rust (FFI) or the disk.
class _CountingConverter extends UnavailableEmbeddedConverter {
  int calls = 0;

  @override
  Future<String> ttsModels() async {
    calls++;
    return jsonEncode({'schema_version': 3, 'providers': [], 'entries': []});
  }

  @override
  Future<String?> ttsModelMetadata({required String modelId, required String root}) async {
    calls++;
    return null;
  }

  @override
  Future<BookLanguageAnalysis> bookLanguage(String path) async {
    calls++;
    return const BookLanguageAnalysis(languages: ['pt'], confirmed: 'pt');
  }
}

void main() {
  testWidgets('opening the reader model menu makes no converter (FFI/disk) call: it reads what is already cached', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = _CountingConverter();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(converter),
        ttsModelRootProvider.overrideWith((_) => '/fixture'),
        systemVoiceLanguagesProvider.overrideWith((ref) async => const ['pt']),
        readerBookLanguageProvider('book-1').overrideWith((ref) async {
          converter.calls++;
          return 'pt';
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(appBar: AppBar(actions: const [ReaderNarrationMenu(bookId: 'book-1')])),
        ),
      ),
    );
    // The reader mounted: the caches fill now, once.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final warm = converter.calls;
    expect(warm, greaterThan(0), reason: 'mounting loads the lists');

    final watch = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('reader-overflow-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    watch.stop();

    expect(find.byType(CheckedPopupMenuItem<Object>), findsWidgets, reason: 'the menu is open');
    expect(converter.calls, warm, reason: 'opening must not call Rust or touch the disk');
  });
}
