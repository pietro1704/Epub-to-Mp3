part of 'convert_screen_test.dart';

void registerManualConversionCompletionCases() {
  testWidgets('manual history retains the job snapshot after preferences change in flight', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final result = Completer<String>.sync();
    ConversionRequest? captured;
    await _pumpManualResult(tester, prefs, (request) {
      captured = request;
      return result.future;
    });
    expect(captured!.ttsPreferences.primary.modelId, 'pt_BR-faber-medium');
    final container = ProviderScope.containerOf(tester.element(find.byType(ConvertScreen)));
    await container.read(settingsProvider.notifier).setTtsPreferences(
      const TtsPreferences(primary: TtsSelection.edge),
    );
    result.complete(jsonEncode({
      'jobId': 'captured-manual',
      'chapters': [{'sourceIndex': 5, 'filename': 'six.mp3'}],
    }));
    await tester.pumpAndSettle();
    final job = (await LocalConversionJobStore(prefs).loadHistory()).jobs.single;
    final options = jsonDecode(job.conversionOptionsJson!);
    expect(options['tts_preferences']['primary']['model_id'], 'pt_BR-faber-medium');
    expect(options['tts_preferences']['secondary']['engine'], 'system');
    expect(options['tts_preferences']['policy_version'], 2);
    expect(options['tts_preferences']['allow_online_fallback'], false);
    expect(container.read(settingsProvider).ttsPreferences.primary.engine, 'edge');
  });

  testWidgets('an ID-only completed result does not fabricate local history', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await _pumpManualResult(tester, prefs, (_) async => 'legacy-id-only');
    await tester.pumpAndSettle();
    expect((await LocalConversionJobStore(prefs).loadHistory()).jobs, isEmpty);
    expect(find.text('Retry'), findsNothing);
    expect(find.byKey(const Key('conversion-job-id')), findsOneWidget);
  });

  for (final missing in [false, true]) {
    testWidgets('completed manifest file read ${missing ? 'failure warns without Retry' : 'persists actual history'}', (tester) async {
      const voiceChannel = MethodChannel('epub_to_mp3/platform_voice');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('manual-history-manifest-');
        await File('${directory.path}/manifest.json').writeAsString(jsonEncode({
          'jobId': 'file-manual-id',
          'title': 'Actual manifest',
          'chapters': [{'sourceIndex': 9, 'filename': 'ten.mp3'}],
        }));
      });
      messenger.setMockMethodCallHandler(voiceChannel, (call) async {
        expect(call.method, anyOf('listen', 'cancel'));
        return null;
      });
      try {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        var conversions = 0;
        final path = '${directory.path}/${missing ? 'missing' : 'manifest'}.json';
        await _pumpManualResult(tester, prefs, (_) async {
          conversions++;
          return path;
        });
        for (var attempt = 0; attempt < 200 && find.byKey(const Key('conversion-job-id')).evaluate().isEmpty; attempt++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        }
        await tester.pumpAndSettle();
        final history = await LocalConversionJobStore(prefs).loadHistory();
        if (missing) {
          expect(history.jobs, isEmpty);
          expect(find.textContaining('Conversion completed, but its history could not be saved:'), findsOneWidget);
        } else {
          expect(history.jobs.single.jobId, 'file-manual-id');
          expect(history.jobs.single.chapters.single.index, 9);
          expect(history.jobs.single.completedOutputs, isEmpty);
        }
        expect(find.byKey(const Key('conversion-job-id')), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        expect(conversions, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        try {
          await tester.runAsync(() => directory.delete(recursive: true));
        } finally {
          messenger.setMockMethodCallHandler(voiceChannel, null);
        }
      }
    });
  }

  for (final code in ['cancelled', 'conversion_failed']) {
    testWidgets('manual $code cannot publish completed history', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var conversions = 0;
      await _pumpManualResult(tester, prefs, (_) async {
        conversions++;
        throw PlatformException(code: code, message: 'Stopped before manifest');
      });
      await tester.pumpAndSettle();
      final history = await LocalConversionJobStore(prefs).loadHistory();
      expect(history.jobs, isEmpty);
      expect(history.unreadableKeys, isEmpty);
      expect(find.byKey(const Key('conversion-job-id')), findsNothing);
      expect(find.textContaining('Stopped before manifest'), findsOneWidget);
      expect(find.textContaining('Conversion completed, but'), findsNothing);
      expect(conversions, 1);
      expect(tester.takeException(), isNull);
    });
  }

}
