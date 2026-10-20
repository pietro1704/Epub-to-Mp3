import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'dart:convert';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeRustConverter extends UnavailableEmbeddedConverter {
  final List<int> requested = [];
  final List<String?> capturedOptions = [];
  Completer<void>? chapterThreeStarted;
  Completer<void>? releaseChapterThree;

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    requested.add(chapterIndex);
    capturedOptions.add(optionsJson);
    if (chapterIndex == 3 && releaseChapterThree != null) {
      chapterThreeStarted?.complete();
      await releaseChapterThree!.future;
    }
    final directory = Directory(outputPath)..createSync(recursive: true);
    final file = File('${directory.path}/chapter.mp3')
      ..writeAsBytesSync([chapterIndex, 0x49, 0x44, 0x33]);
    return ConvertedChapterAudio(
      chapterIndex: chapterIndex,
      path: file.path,
      title: 'Chapter $chapterIndex',
    );
  }
}

class CancellableBlockingConverter extends FakeRustConverter
    implements CancellableEmbeddedConverter {
  final started = Completer<void>();
  final blocked = Completer<ConvertedChapterAudio>();
  final cancelledOutputs = <String>[];
  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    if (chapterIndex != 0) {
      return super.convertChapter(
        inputPath: inputPath,
        outputPath: outputPath,
        chapterIndex: chapterIndex,
        optionsJson: optionsJson,
      );
    }
    requested.add(chapterIndex);
    capturedOptions.add(optionsJson);
    started.complete();
    return blocked.future;
  }

  @override
  Future<void> cancelConversion({String? inputPath, String? outputPath}) async {
    cancelledOutputs.add(outputPath!);
    if (!blocked.isCompleted) {
      blocked.completeError(
        EmbeddedConversionFailure('CANCELLED', 'Conversion cancelled'),
      );
    }
  }
}

class PolicyMetadataConverter extends FakeRustConverter {
  PolicyMetadataConverter({this.reportFallback = true});
  final bool reportFallback;
  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    final result = await super.convertChapter(
      inputPath: inputPath,
      outputPath: outputPath,
      chapterIndex: chapterIndex,
      optionsJson: optionsJson,
    );
    return ConvertedChapterAudio(
      chapterIndex: result.chapterIndex,
      path: result.path,
      title: result.title,
      usedSelections: const [
        TtsSelection(engine: 'edge', voice: 'pt-BR-FranciscaNeural'),
      ],
      fallbackUsed: reportFallback,
      ttsPolicyState: chapterIndex == 0
          ? {'consecutive_failures': 1}
          : {'consecutive_failures': 2},
    );
  }
}

List<FulltextChapter> _chapters() => [
  for (var index = 0; index < 8; index++)
    FulltextChapter(index: index, name: 'Chapter $index', text: 'Text $index'),
];

Future<ConversionJobCoordinator> _coordinator() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConversionJobCoordinator(LocalConversionJobStore(prefs));
}

void main() {
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

  test('converts only the moving playback window', () async {
    final converter = FakeRustConverter();
    final changes = StreamController<int>.broadcast();
    final coordinator = await _coordinator();
    final root = await Directory.systemTemp.createTemp('rust-playback-window-');
    final convertedThree = Completer<void>();
    final convertedSeven = Completer<void>();

    final jobFuture =
        RustPlaybackConversionService(
          converter: converter,
          coordinator: coordinator,
        ).convert(
          optionsJson: const TtsPreferences().optionsJson(),
          bookId: 'book-window',
          jobId: 'listen-window',
          inputPath: '/book.epub',
          outputDirectory: root.path,
          chapters: _chapters(),
          initialChapterIndex: 2,
          playbackChapterChanges: changes.stream,
          isActive: () => true,
          onChapterCompleted: (chapter, outputPath, updatedJob) async {
            expect(outputPath, isNotEmpty);
            expect(updatedJob.chapters, isNotEmpty);
            if (chapter.index == 3) convertedThree.complete();
            if (chapter.index == 7) convertedSeven.complete();
          },
        );

    try {
      await convertedThree.future.timeout(const Duration(seconds: 2));
      changes.add(6);
      await convertedSeven.future.timeout(const Duration(seconds: 2));
      await changes.close();
      final job = await jobFuture.timeout(const Duration(seconds: 2));

      expect(converter.requested, [2, 3, 6, 7]);
      expect(
        converter.capturedOptions,
        everyElement(const TtsPreferences().optionsJson()),
      );
      expect(
        job.chapters
            .where((chapter) => chapter.status == 'completed')
            .map((chapter) => chapter.index),
        [2, 3, 6, 7],
      );
    } finally {
      await changes.close();
      await root.delete(recursive: true);
    }
  });

  test(
    'deletes an in-flight chapter that leaves the window before commit',
    () async {
      final converter = FakeRustConverter()
        ..chapterThreeStarted = Completer<void>()
        ..releaseChapterThree = Completer<void>();
      final changes = StreamController<int>.broadcast();
      final coordinator = await _coordinator();
      final root = await Directory.systemTemp.createTemp(
        'rust-playback-stale-',
      );
      final convertedSeven = Completer<void>();

      final jobFuture =
          RustPlaybackConversionService(
            converter: converter,
            coordinator: coordinator,
          ).convert(
            bookId: 'book-stale',
            jobId: 'listen-stale',
            inputPath: '/book.epub',
            outputDirectory: root.path,
            chapters: _chapters(),
            initialChapterIndex: 2,
            playbackChapterChanges: changes.stream,
            isActive: () => true,
            onChapterCompleted: (chapter, outputPath, updatedJob) async {
              expect(outputPath, isNotEmpty);
              expect(updatedJob.chapters, isNotEmpty);
              if (chapter.index == 7) convertedSeven.complete();
            },
          );

      try {
        await converter.chapterThreeStarted!.future.timeout(
          const Duration(seconds: 2),
        );
        changes.add(6);
        converter.releaseChapterThree!.complete();
        await convertedSeven.future.timeout(const Duration(seconds: 2));
        changes.close();
        final job = await jobFuture.timeout(const Duration(seconds: 2));

        expect(converter.requested, [2, 3, 6, 7]);
        expect(
          File('${root.path}/streaming/chapter_3/chapter.mp3').existsSync(),
          isFalse,
        );
        expect(
          job.chapters.singleWhere((chapter) => chapter.index == 3).status,
          'pending',
        );
        expect(
          job.chapters
              .where((chapter) => chapter.status == 'completed')
              .map((chapter) => chapter.index),
          [2, 6, 7],
        );
      } finally {
        if (!converter.releaseChapterThree!.isCompleted) {
          converter.releaseChapterThree!.complete();
        }
        await changes.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('retains EPUB positions while excluding empty chapters', () async {
    final converter = FakeRustConverter();
    final changes = StreamController<int>.broadcast();
    final coordinator = await _coordinator();
    final root = await Directory.systemTemp.createTemp('rust-playback-sparse-');
    final convertedZero = Completer<void>();
    final convertedTwo = Completer<void>();
    await coordinator.createJob(
      bookId: 'book-sparse',
      jobId: 'listen-sparse',
      chapters: [
        const LocalConversionChapterSpec(0, 'Chapter 0'),
        const LocalConversionChapterSpec(1, 'Empty chapter'),
        const LocalConversionChapterSpec(2, 'Chapter 2'),
      ],
    );

    final jobFuture =
        RustPlaybackConversionService(
          converter: converter,
          coordinator: coordinator,
        ).convert(
          bookId: 'book-sparse',
          jobId: 'listen-sparse',
          inputPath: '/book.epub',
          outputDirectory: root.path,
          chapters: const [
            FulltextChapter(index: 0, name: 'Chapter 0', text: 'Readable 0'),
            FulltextChapter(index: 1, name: 'Empty chapter', text: '  '),
            FulltextChapter(index: 2, name: 'Chapter 2', text: 'Readable 2'),
          ],
          initialChapterIndex: 0,
          playbackChapterChanges: changes.stream,
          isActive: () => true,
          onChapterCompleted: (chapter, outputPath, updatedJob) async {
            expect(outputPath, isNotEmpty);
            expect(updatedJob.chapters, isNotEmpty);
            if (chapter.index == 0) convertedZero.complete();
            if (chapter.index == 2) convertedTwo.complete();
          },
        );

    try {
      await convertedZero.future.timeout(const Duration(seconds: 2));
      changes.add(2);
      await convertedTwo.future.timeout(const Duration(seconds: 2));
      changes.close();
      final job = await jobFuture.timeout(const Duration(seconds: 2));

      expect(converter.requested, [0, 2]);
      expect(job.chapters.map((chapter) => chapter.index), [0, 2]);
      expect(
        job.chapters.every((chapter) => chapter.status == 'completed'),
        isTrue,
      );
    } finally {
      if (!changes.isClosed) await changes.close();
      try {
        await jobFuture;
      } catch (_) {}
      await root.delete(recursive: true);
    }
  });
}
