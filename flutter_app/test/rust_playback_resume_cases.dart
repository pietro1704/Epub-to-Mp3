part of 'rust_playback_conversion_test.dart';

void registerRustPlaybackResumeCases() {
  test(
    'legacy recorded Edge voice is preserved rather than changed to Faber',
    () {
      final time = DateTime.now().toUtc();
      final legacy = LocalConversionJob(
        bookId: 'legacy',
        jobId: 'job',
        chapters: const [],
        status: LocalConversionJobStatus.pending,
        createdAt: time,
        updatedAt: time,
      ).toJson();
      legacy['engine'] = 'edge';
      legacy['voice'] = 'en-US-GuyNeural';
      legacy['language'] = 'en';
      final migrated = LocalConversionJob.fromJson(legacy);
      final captured = jsonDecode(migrated.conversionOptionsJson!) as Map;
      expect(captured['tts_preferences']['primary']['engine'], 'edge');
      expect(
        captured['tts_preferences']['primary']['voice'],
        'en-US-GuyNeural',
      );
      expect(captured['language'], 'en');
    },
  );

  test(
    'resume keeps saved Faber policy when current defaults are Edge',
    () async {
      final root = await Directory.systemTemp.createTemp('tts-policy-resume-');
      final coordinator = await _coordinator();
      var job = await coordinator.createJob(
        bookId: 'resume',
        jobId: 'job',
        chapters: const [
          LocalConversionChapterSpec(0, 'Chapter 0'),
          LocalConversionChapterSpec(1, 'Chapter 1'),
        ],
        conversionOptionsJson: const TtsPreferences().optionsJson(
          modelsRoot: '/old-models',
          language: 'pt',
        ),
      );
      final existingAudio = File('${root.path}/existing.mp3');
      await existingAudio.writeAsBytes([1, 2, 3]);
      job = await coordinator.completeChapter(job, 0, existingAudio.path);
      final converter = FakeRustConverter();
      final changes = StreamController<int>.broadcast();
      try {
        final resumed =
            await RustPlaybackConversionService(
              converter: converter,
              coordinator: coordinator,
            ).convert(
              optionsJson: const TtsPreferences(
                primary: TtsSelection.edge,
              ).optionsJson(modelsRoot: '/new-models', language: 'en'),
              bookId: 'resume',
              jobId: 'job',
              inputPath: '/book.epub',
              outputDirectory: root.path,
              chapters: _chapters().take(2).toList(),
              initialChapterIndex: 1,
              playbackChapterChanges: changes.stream,
              isActive: () => true,
            );
        expect(converter.requested, [1]);
        final actual = jsonDecode(converter.capturedOptions.single!) as Map;
        expect(
          actual['tts_preferences']['primary']['model_id'],
          'pt_BR-faber-medium',
        );
        expect(actual['language'], 'pt');
        expect(actual['models_root'], '/new-models');
        final stored = await coordinator.store.load('resume', 'job');
        expect(stored!.conversionOptionsJson, resumed.conversionOptionsJson);
        expect(stored.chapters.first.outputPath, existingAudio.path);
        final manifest =
            jsonDecode(await File('${root.path}/manifest.json').readAsString())
                as Map;
        expect(
          manifest['conversionOptionsJson'],
          resumed.conversionOptionsJson,
        );
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'legacy completed audio without voice identity requires a new conversion',
    () async {
      final root = await Directory.systemTemp.createTemp('tts-unknown-resume-');
      final coordinator = await _coordinator();
      final time = DateTime.now().toUtc();
      await coordinator.store.save(
        LocalConversionJob(
          bookId: 'legacy',
          jobId: 'job',
          chapters: const [
            LocalConversionChapter(
              index: 0,
              name: 'Chapter 0',
              status: 'completed',
              outputPath: '/old.mp3',
            ),
          ],
          status: LocalConversionJobStatus.completed,
          createdAt: time,
          updatedAt: time,
        ),
      );
      final converter = FakeRustConverter();
      final changes = StreamController<int>.broadcast();
      try {
        await expectLater(
          RustPlaybackConversionService(
            converter: converter,
            coordinator: coordinator,
          ).convert(
            bookId: 'legacy',
            jobId: 'job',
            inputPath: '/book.epub',
            outputDirectory: root.path,
            chapters: _chapters().take(1).toList(),
            initialChapterIndex: 0,
            playbackChapterChanges: changes.stream,
            isActive: () => true,
          ),
          throwsA(
            isA<EmbeddedConversionFailure>().having(
              (error) => error.code,
              'code',
              'RESUME_VOICE_UNKNOWN',
            ),
          ),
        );
        expect(converter.requested, isEmpty);
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

}
