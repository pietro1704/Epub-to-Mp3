import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeRustConverter extends UnavailableEmbeddedConverter {
  final List<int> requested = [];
  Completer<void>? chapterThreeStarted;
  Completer<void>? releaseChapterThree;

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
  }) async {
    requested.add(chapterIndex);
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
  test('converts only the moving playback window', () async {
    final converter = FakeRustConverter();
    final changes = StreamController<int>.broadcast();
    final coordinator = await _coordinator();
    final root = await Directory.systemTemp.createTemp('rust-playback-window-');
    final convertedThree = Completer<void>();

    final jobFuture =
        RustPlaybackConversionService(
          converter: converter,
          coordinator: coordinator,
        ).convert(
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
          },
        );

    try {
      await convertedThree.future.timeout(const Duration(seconds: 2));
      changes.add(6);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      changes.close();
      final job = await jobFuture.timeout(const Duration(seconds: 2));

      expect(converter.requested, [2, 3, 6, 7]);
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
