import 'dart:convert';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingHistoryStore extends LocalConversionJobStore {
  _FailingHistoryStore(super.prefs);

  @override
  Future<void> save(LocalConversionJob job) async =>
      throw StateError('Storage full');
}

void main() {
  testWidgets(
    'completed conversion stays completed when saving history fails',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var conversions = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            localConversionJobStoreProvider.overrideWithValue(
              _FailingHistoryStore(prefs),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('pt', 'BR'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConvertScreen(
              initialFilePath: '/tmp/book.epub',
              startConversion: (_) async {
                conversions++;
                return jsonEncode({
                  'jobId': 'completed-rust-id',
                  'title': 'Completed Book',
                  'chapters': [
                    {'sourceIndex': 0, 'title': 'One', 'filename': 'one.mp3'},
                  ],
                });
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Start conversion'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Start conversion'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('completed-rust-id'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('completed-rust-id'), findsOneWidget);
      expect(
        find.textContaining(
          'Conversão concluída, mas não foi possível salvar o histórico:',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      expect(conversions, 1);
    },
  );

  testWidgets(
    'manual Rust manifest persists local Jobs history without desktop HTTP',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        var httpReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              apiClientProvider.overrideWith((ref) {
                httpReads++;
                throw StateError(
                  'Local manual conversion must not request HTTP',
                );
              }),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ConvertScreen(
                initialFilePath: '/tmp/book.epub',
                startConversion: (_) async => jsonEncode({
                  'manifest': {
                    'jobId': 'rust-manual-id',
                    'title': 'Manual Book',
                    'chapters': [
                      {
                        'index': 0,
                        'sourceIndex': 5,
                        'title': 'Original Chapter Six',
                        'filename': 'chapter_0001.mp3',
                      },
                    ],
                    'usedSelections': [TtsSelection.faber.toJson()],
                  },
                }),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Start conversion'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Start conversion'));
        await tester.pumpAndSettle();
        expect(httpReads, 0);
        final history = await LocalConversionJobStore(prefs).loadHistory();
        expect(history.jobs, hasLength(1));
        final job = history.jobs.single;
        expect(job.jobId, 'rust-manual-id');
        expect(job.toJson()['bookTitle'], 'Manual Book');
        expect(job.status, LocalConversionJobStatus.completed);
        expect(job.chapters.single.index, 5);
        expect(
          job.chapters.single.outputPath,
          isNull,
          reason:
              'An injected manifest alone does not establish an audio directory',
        );
        expect(job.usedSelections.single.modelId, 'pt_BR-faber-medium');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final secondaryVoice in <String?>[null, 'pt-BR-AntonioNeural']) {
    testWidgets(
      'manual Edge retains secondary only when full selection differs: $secondaryVoice',
      (tester) async {
        final saved = TtsPreferences(
          secondary: TtsSelection(engine: 'edge', voice: secondaryVoice),
          allowOnlineFallback: true,
        );
        SharedPreferences.setMockInitialValues({
          'ttsPreferences': jsonEncode(saved.toJson()),
        });
        final prefs = await SharedPreferences.getInstance();
        ConversionRequest? captured;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ConvertScreen(
                initialFilePath: '/tmp/book.epub',
                startConversion: (request) async {
                  captured = request;
                  return 'manual';
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use audio preferences'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edge · Online').last);
        await tester.pumpAndSettle();
        final checkbox = find.text(
          'Allow configured secondary for this conversion',
        );
        await Scrollable.ensureVisible(
          tester.element(checkbox),
          alignment: 0.5,
        );
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Start conversion'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Start conversion'));
        await tester.pumpAndSettle();
        final effective = captured!.ttsPreferences;
        expect(effective.primary.voice, 'pt-BR-AntonioNeural');
        expect(effective.allowOnlineFallback, true);
        if (secondaryVoice == null) {
          expect(effective.secondary!.engine, 'edge');
          expect(effective.secondary!.voice, isNull);
        } else {
          expect(effective.secondary, isNull);
        }
        expect(prefs.getString('ttsPreferences'), jsonEncode(saved.toJson()));
      },
    );
  }

  testWidgets('completed manual conversion displays the actual native voice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(
            initialFilePath: '/tmp/book.epub',
            startConversion: (_) async =>
                '{"jobId":"actual-job","usedSelections":[{"engine":"piper","model_id":"pt_BR-faber-medium","voice":null}]}',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Start conversion'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Start conversion'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Used voice: Piper · pt_BR-faber-medium'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Used voice: Piper · pt_BR-faber-medium'), findsOneWidget);
  });

  testWidgets('manual narration options use Brazilian Portuguese labels', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          locale: Locale('pt', 'BR'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usar preferências de áudio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Faber medium · Sem internet').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Permitir a voz secundária configurada nesta conversão'),
      findsOneWidget,
    );
    expect(
      find.text('Allow configured secondary for this conversion'),
      findsNothing,
    );
  });

  testWidgets(
    'manual Edge override remains strict and does not change saved primary',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ConversionRequest? captured;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConvertScreen(
              initialFilePath: '/tmp/book.epub',
              startConversion: (request) async {
                captured = request;
                return 'manual';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use audio preferences'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edge · Online').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Start conversion'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Start conversion'));
      await tester.pumpAndSettle();
      expect(captured!.ttsPreferences.primary.engine, 'edge');
      expect(captured!.ttsPreferences.secondary, isNull);
      expect(prefs.getString('ttsPreferences'), isNull);
    },
  );
  testWidgets('renders manual conversion controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(),
        ),
      ),
    );

    expect(find.text('Choose EPUB or PDF'), findsOneWidget);
    expect(find.text('Engine'), findsOneWidget);
    expect(find.text('Use audio preferences'), findsOneWidget);
    expect(find.text('Voice'), findsNothing);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Chapter range'), findsOneWidget);
    expect(find.text('Options'), findsOneWidget);
    expect(find.text('Start conversion'), findsOneWidget);
    expect(find.text('Piper'), findsNothing);
  });

  testWidgets(
    'submits the selected file through the injected existing service',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      String? submittedPath;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConvertScreen(
              initialFilePath: '/tmp/book.epub',
              startConversion: (request) async {
                expect(request.engine, 'piper');
                expect(
                  request.ttsPreferences.primary.modelId,
                  'pt_BR-faber-medium',
                );
                expect(request.ttsPreferences.secondary, isNull);
                submittedPath = request.filePath;
                return 'job-1';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start conversion'));
      await tester.pumpAndSettle();

      expect(submittedPath, '/tmp/book.epub');
      expect(find.text('job-1'), findsOneWidget);
    },
  );
}
