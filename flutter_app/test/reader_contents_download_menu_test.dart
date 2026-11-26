import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_app/services/storage/local_conversion_store.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_app/views/reader_toc_audio_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

EbookFulltext _book() => EbookFulltext.fromJson({
  'jobId': 'b',
  'bookTitle': 'Sample',
  'chapters': [
    for (var i = 0; i < 3; i++) {'index': i, 'name': 'Chapter $i', 'text': 'Text of chapter $i.'},
  ],
});

void main() {
  testWidgets('contents menu retries from the first failed chapter and downloads the rest', (t) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalConversionJobStore(prefs);
    await store.save(LocalConversionJob(
      bookId: 'b',
      jobId: 'local-b',
      status: LocalConversionJobStatus.running,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      chapters: const [
        LocalConversionChapter(index: 0, name: 'Chapter 0', status: 'completed', outputPath: '/a/0.mp3'),
        LocalConversionChapter(index: 1, name: 'Chapter 1', status: 'failed', error: 'boom'),
      ],
    ));
    final calls = <String>[];
    await t.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        localConversionJobStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: InstantReaderView(
            fulltext: _book(),
            bookId: 'b',
            downloadActions: ReaderDownloadActions(
              downloadAll: () async => calls.add('all'),
              cancel: () async => calls.add('cancel'),
              retryFrom: (i) async => calls.add('retry$i'),
              shareAudio: () async => calls.add('share'),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    Future<void> openContentsMenu() async {
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
    }

    await openContentsMenu();
    expect(find.text('Cancel downloads'), findsNothing);
    await t.tap(find.text('Retry failed chapters'));
    await t.pumpAndSettle();
    expect(calls, ['retry1']);

    await openContentsMenu();
    await t.tap(find.text('Download for offline'));
    await t.pumpAndSettle();
    expect(calls, ['retry1', 'all']);

    await openContentsMenu();
    await t.tap(find.text('Share available audio'));
    await t.pumpAndSettle();
    expect(calls, ['retry1', 'all', 'share']);
  });
}
