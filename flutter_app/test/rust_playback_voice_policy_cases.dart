part of 'rust_playback_conversion_test.dart';

void registerRustPlaybackVoicePolicyCases() {
  for (final fallbackUsed in [false, true]) {
    test(
      'same resolved Edge voice reports secondary role only from Rust fallbackUsed=$fallbackUsed',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'native-fallback-role-',
        );
        final coordinator = await _coordinator();
        final converter = PolicyMetadataConverter(reportFallback: fallbackUsed);
        final changes = StreamController<int>.broadcast();
        var notices = 0;
        try {
          final job =
              await RustPlaybackConversionService(
                converter: converter,
                coordinator: coordinator,
              ).convert(
                optionsJson: const TtsPreferences(
                  primary: TtsSelection(
                    engine: 'edge',
                    voice: 'pt-BR-FranciscaNeural',
                  ),
                  secondary: TtsSelection.edge,
                  allowOnlineFallback: true,
                ).optionsJson(),
                bookId: 'same-edge',
                jobId: 'job',
                inputPath: '/book.epub',
                outputDirectory: root.path,
                chapters: _chapters().take(1).toList(),
                initialChapterIndex: 0,
                playbackChapterChanges: changes.stream,
                isActive: () => true,
                onSecondaryUsed: (_) async {
                  notices++;
                },
              );
          expect(notices, fallbackUsed ? 1 : 0);
          expect(job.fallbackUsed, fallbackUsed);
          expect(
            (await coordinator.store.load(
              'same-edge',
              'job',
            ))!.chapters.single.fallbackUsed,
            fallbackUsed,
          );
        } finally {
          await changes.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'Rust policy state and actual fallback voice persist across chapter calls',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'native-policy-chain-',
      );
      final coordinator = await _coordinator();
      final converter = PolicyMetadataConverter();
      final changes = StreamController<int>.broadcast();
      var notices = 0;
      try {
        final job =
            await RustPlaybackConversionService(
              converter: converter,
              coordinator: coordinator,
            ).convert(
              optionsJson: const TtsPreferences(
                secondary: TtsSelection.edge,
                allowOnlineFallback: true,
              ).optionsJson(),
              bookId: 'policy',
              jobId: 'job',
              inputPath: '/book.epub',
              outputDirectory: root.path,
              chapters: _chapters().take(2).toList(),
              initialChapterIndex: 0,
              playbackChapterChanges: changes.stream,
              isActive: () => true,
              onSecondaryUsed: (_) async {
                notices++;
              },
            );
        expect(jsonDecode(converter.capturedOptions[1]!)['tts_policy_state'], {
          'consecutive_failures': 1,
        });
        expect(job.ttsPolicyState, {'consecutive_failures': 2});
        expect(notices, 1);
        final restored = await coordinator.store.load('policy', 'job');
        expect(restored!.usedSelections.single.voice, 'pt-BR-FranciscaNeural');
        expect(
          restored.chapters.every(
            (chapter) => chapter.usedSelections.single.engine == 'edge',
          ),
          true,
        );
        expect(restored.fallbackNoticeShown, true);
        final manifest = jsonDecode(
          await File('${root.path}/manifest.json').readAsString(),
        );
        expect(manifest['ttsPolicyState'], {'consecutive_failures': 2});
        expect(
          manifest['usedSelections'].single['voice'],
          'pt-BR-FranciscaNeural',
        );
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'owner cancellation stops nonstream native chapter without committing audio',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cancel-native-listen-',
      );
      final converter = CancellableBlockingConverter();
      final coordinator = await _coordinator();
      final changes = StreamController<int>.broadcast();
      final service = RustPlaybackConversionService(
        converter: converter,
        coordinator: coordinator,
      );
      final pending = service.convert(
        bookId: 'cancel',
        jobId: 'job',
        inputPath: '/book.epub',
        outputDirectory: root.path,
        chapters: _chapters(),
        initialChapterIndex: 0,
        playbackChapterChanges: changes.stream,
        isActive: () => true,
      );
      try {
        await converter.started.future.timeout(const Duration(seconds: 2));
        await service.cancel();
        final result = await pending.timeout(const Duration(seconds: 2));
        expect(
          converter.cancelledOutputs.single,
          contains('/streaming/chapter_0_'),
        );
        expect(converter.requested, [0]);
        expect(result.chapters.first.status, 'pending');
        expect(result.completedOutputs, isEmpty);
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'window change cancels nonstream chapter and preserves captured voice for next window',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cancel-window-native-',
      );
      final converter = CancellableBlockingConverter();
      final coordinator = await _coordinator();
      final changes = StreamController<int>.broadcast();
      final options = const TtsPreferences().optionsJson();
      final service = RustPlaybackConversionService(
        converter: converter,
        coordinator: coordinator,
      );
      final pending = service.convert(
        optionsJson: options,
        bookId: 'window',
        jobId: 'job',
        inputPath: '/book.epub',
        outputDirectory: root.path,
        chapters: _chapters().take(5).toList(),
        initialChapterIndex: 0,
        playbackChapterChanges: changes.stream,
        isActive: () => true,
        onChapterCompleted: (_, _, _) async {
          unawaited(changes.close());
        },
      );
      try {
        await converter.started.future.timeout(const Duration(seconds: 2));
        changes.add(4);
        final result = await pending.timeout(const Duration(seconds: 2));
        expect(
          converter.cancelledOutputs.single,
          contains('/streaming/chapter_0_'),
        );
        expect(converter.requested, [0, 4]);
        expect(converter.capturedOptions, everyElement(options));
        expect(result.chapters.first.status, 'pending');
        expect(result.chapters.last.status, 'completed');
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

}
