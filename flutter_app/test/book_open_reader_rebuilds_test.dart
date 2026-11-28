import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/book_open_screen.dart';
import 'package:flutter_app/screens/library_screen.dart' show libraryStoreProvider;
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/storage/local_fulltext_cache.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player_service.dart';

class _Cache extends LocalFulltextCache {
  _Cache(this.payload) : super(directoryProvider: () async => throw StateError('unused'));
  final EbookFulltext payload;
  @override
  Future<EbookFulltext?> read(String bookId) async => payload;
  @override
  Future<void> save(EbookFulltext payload, String bookId) async {}
}

// FLUTTER-PERF-8-READER-REBUILDS: the reader body listened to the whole library, so a change
// to a field it does not show (the resume position, tags, last played) rebuilt the reader.
void main() {
  testWidgets('a library change unrelated to title, path or cover does not rebuild the reader', (t) async {
    final book = BookEntity(
      id: 'b1',
      title: 'Livro',
      filePath: '/tmp/livro.epub',
      displayFilename: 'livro.epub',
      addedAt: DateTime(2025),
    );
    SharedPreferences.setMockInitialValues({'library.books.v1': '[${book.encode()}]'});
    final prefs = await SharedPreferences.getInstance();
    final fulltext = EbookFulltext.fromJson({
      'jobId': 'j',
      'bookTitle': 'Livro',
      'chapters': [
        {'index': 0, 'name': 'Capítulo', 'text': 'Um texto em português para ouvir.'},
      ],
    });
    final player = FakeAudioPlayerService();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          localFulltextCacheProvider.overrideWithValue(_Cache(fulltext)),
          globalAudioPlayerProvider.overrideWithValue(player),
          embeddedConverterProvider.overrideWithValue(UnavailableEmbeddedConverter()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: BookOpenScreen(bookId: 'b1')),
        ),
      ),
    );
    await t.pumpAndSettle();
    final store = ProviderScope.containerOf(t.element(find.byType(BookOpenScreen))).read(libraryStoreProvider);
    final stored = store.books.single;

    var before = debugReaderBodyBuilds;
    stored.lastPositionSeconds = 12;
    store.update(stored);
    await t.pump();
    expect(debugReaderBodyBuilds, before, reason: 'resume position is not shown by the reader');

    before = debugReaderBodyBuilds;
    stored.title = 'Livro revisado';
    store.update(stored);
    await t.pump();
    expect(debugReaderBodyBuilds, greaterThan(before), reason: 'the title is shown, so it rebuilds');
    await t.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}
