import 'dart:convert';
import 'package:flutter_app/models/tts_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/jobs_list_screen.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Android Jobs keeps supported log controls and the real Rust job ID',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'library.books.v1': jsonEncode([
          {
            'id': 'android-book',
            'title': 'Android Book',
            'filePath': '/android.epub',
            'displayFilename': 'android.epub',
            'addedAt': '2026-01-01T00:00:00Z',
          },
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      await LocalConversionJobStore(prefs).save(
        LocalConversionJob(
          bookId: 'android-book',
          jobId: 'android-real-id',
          status: LocalConversionJobStatus.completed,
          chapters: const [],
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? observedJobId;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'jobLog');
        observedJobId = call.arguments['jobId'] as String;
        return '["Android durable log"]';
      });
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              embeddedConverterProvider.overrideWithValue(
                AndroidEmbeddedConverter(),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: JobsListScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.article_outlined), findsOneWidget);
        await tester.tap(find.byIcon(Icons.article_outlined));
        await tester.pumpAndSettle();
        expect(observedJobId, 'android-real-id');
        expect(find.text('Android durable log'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Android Book'));
        await tester.pumpAndSettle();
        expect(find.text('Conversion log'), findsOneWidget);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  testWidgets('Jobs opens a persisted conversion and its error without HTTP', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'library.books.v1': jsonEncode([
        {
          'id': 'book-1',
          'title': 'The Fellowship',
          'filePath': '/book.epub',
          'displayFilename': 'book.epub',
          'addedAt': '2026-01-01T00:00:00Z',
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final coordinator = ConversionJobCoordinator(
      LocalConversionJobStore(prefs),
    );
    var job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'literal-rust-job-id',
      chapters: const [LocalConversionChapterSpec(2, 'A Long-expected Party')],
    );
    await coordinator.failChapter(job, 2, 'Installed voice is unavailable');
    await prefs.setString('local-conversion.v1:damaged', '{invalid');
    var httpReads = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWith((ref) {
            httpReads++;
            throw StateError('Jobs must not request HTTP');
          }),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: JobsListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(httpReads, 0);
    expect(find.text('The Fellowship'), findsOneWidget);
    expect(find.textContaining('1 saved conversion record'), findsOneWidget);
    await tester.tap(find.text('The Fellowship'));
    await tester.pumpAndSettle();
    expect(find.text('literal-rust-job-id'), findsOneWidget);
    expect(find.text('A Long-expected Party'), findsOneWidget);
    expect(find.textContaining('Installed voice is unavailable'), findsWidgets);
    expect(httpReads, 0);
  });
  testWidgets(
    'Jobs shows storage read failure without requesting HTTP',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var httpReads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            localConversionHistoryProvider.overrideWith((ref) async {
              throw StateError('Local history storage unavailable');
            }),
            apiClientProvider.overrideWith((ref) {
              httpReads++;
              throw StateError('Jobs must not request HTTP');
            }),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: JobsListScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Local history storage unavailable'),
        findsOneWidget,
      );
      expect(httpReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final initiallyFails in [false, true]) {
    testWidgets(
      'pull to refresh discovers a saved job from ${initiallyFails ? 'error' : 'empty'} history',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = LocalConversionJobStore(prefs);
        var reads = 0;
        var httpReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              localConversionHistoryProvider.overrideWith((ref) async {
                if (initiallyFails && reads++ == 0) {
                  throw StateError('Temporary local history failure');
                }
                return store.loadHistory();
              }),
              apiClientProvider.overrideWith((ref) {
                httpReads++;
                throw StateError('Jobs must not request HTTP');
              }),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: JobsListScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          initiallyFails
              ? find.textContaining('Temporary local history failure')
              : find.text('No conversions yet'),
          findsOneWidget,
        );
        await ConversionJobCoordinator(store).createJob(
          bookId: 'saved-after-mount',
          jobId: 'durable-refresh-job',
          chapters: const [LocalConversionChapterSpec(0, 'One')],
        );
        expect(find.text('saved-after-mount'), findsNothing);
        final start =
            tester.getTopLeft(find.byType(ListView)) + const Offset(80, 40);
        await tester.dragFrom(start, const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(find.text('saved-after-mount'), findsOneWidget);
        expect(httpReads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manual manifest title and actual voice receipts survive reopening Jobs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await LocalConversionJobStore(prefs).saveCompletedManifest(
      bookId: '/tmp/unimported.epub',
      startedAt: DateTime.utc(2026),
      manifest: {
        'jobId': 'manual-receipt-id', 'title': 'Unimported manual book',
        'usedSelections': [TtsSelection.faber.toJson(), TtsSelection.edge.toJson()],
        'fallbackUsed': true,
        'chapters': [{'sourceIndex': 5, 'title': 'Six'}],
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWith((ref) {
            throw StateError('Manual history must not request HTTP');
          }),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: JobsListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unimported manual book'));
    await tester.pumpAndSettle();
    expect(find.text('manual-receipt-id'), findsOneWidget);
    expect(find.textContaining('Used voice: Piper'), findsOneWidget);
    expect(find.textContaining('pt_BR-faber-medium'), findsOneWidget);
    expect(find.textContaining('Edge'), findsOneWidget);
    expect(find.textContaining('Secondary voice used for an isolated segment.'), findsOneWidget);
  });

}
