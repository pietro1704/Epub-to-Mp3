part of 'convert_screen_test.dart';

void registerManualConversionHistoryCases() {
  testWidgets(
    'completed conversion stays completed when saving history fails',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var conversions = 0;
      final refusing = _RefusingHistoryPreferences();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            localConversionJobStoreProvider.overrideWithValue(
              LocalConversionJobStore(refusing),
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
      expect(refusing.writes, 1);
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

}
