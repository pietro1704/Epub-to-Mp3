part of 'convert_screen_test.dart';

void registerManualConversionControlsCases() {
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
                expect(request.ttsPreferences.secondary!.engine, 'system');
                expect(request.ttsPreferences.policyVersion, 2);
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
