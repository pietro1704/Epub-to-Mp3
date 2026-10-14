import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/growing_chapter_audio_source.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';

class WindowStreamingConverter extends UnavailableEmbeddedConverter
    implements StreamingChapterConverter {
  final release = Completer<ConvertedChapterAudio>();
  String? request;
  String? cancelled;
  GrowingChapterAudioSource? source;
  @override
  Future<ConvertedChapterAudio> streamChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    required Future<void> Function(GrowingChapterAudioSource) onFirstAudio,
  }) async {
    request = outputPath;
    final chunk = File('$outputPath/0.mp3')..writeAsBytesSync([1, 2, 3]);
    source = GrowingChapterAudioSource(outputPath);
    await source!.append(0, chunk.path);
    await onFirstAudio(source!);
    return release.future;
  }

  @override
  Future<void> cancelStreamingChapter(String outputPath) async {
    cancelled = outputPath;
    source?.fail(StateError('cancelled'));
    if (!release.isCompleted) release.completeError(StateError('cancelled'));
  }
}

void main() {
  test(
    'window shutdown cancels the live request after early bytes without publishing completion',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final coordinator = ConversionJobCoordinator(
        LocalConversionJobStore(prefs),
      );
      final root = await Directory.systemTemp.createTemp('stream-window-');
      final changes = StreamController<int>.broadcast();
      final converter = WindowStreamingConverter();
      final early = Completer<void>();
      var completed = false;
      final job =
          RustPlaybackConversionService(
            converter: converter,
            coordinator: coordinator,
          ).convert(
            bookId: 'book',
            jobId: 'job',
            inputPath: '/book.epub',
            outputDirectory: root.path,
            chapters: [
              FulltextChapter(index: 0, name: 'Chapter0', text: 'Text0'),
            ],
            initialChapterIndex: 0,
            playbackChapterChanges: changes.stream,
            isActive: () => true,
            onChapterStreaming: (chapter, source) async {
              expect(source.isComplete, false);
              expect(await (await source.request()).stream.first, [1, 2, 3]);
              early.complete();
            },
            onChapterCompleted: (_, _, _) async {
              completed = true;
            },
          );
      await early.future;
      await changes.close();
      final result = await job;
      expect(converter.cancelled, converter.request);
      expect(converter.request, contains('/streaming/chapter_0_'));
      expect(completed, false);
      expect(result.status, LocalConversionJobStatus.pending);
      await root.delete(recursive: true);
    },
  );

  test(
    'completed queued stream retains immutable bytes after the window moves',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final coordinator = ConversionJobCoordinator(
        LocalConversionJobStore(prefs),
      );
      final root = await Directory.systemTemp.createTemp(
        'completed-stream-window-',
      );
      final changes = StreamController<int>.broadcast();
      final converter = WindowStreamingConverter();
      final early = Completer<void>();
      var active = true;
      var announcedCompletion = false;
      final job =
          RustPlaybackConversionService(
            converter: converter,
            coordinator: coordinator,
          ).convert(
            bookId: 'book',
            jobId: 'job',
            inputPath: '/book.epub',
            outputDirectory: root.path,
            chapters: [
              FulltextChapter(index: 0, name: 'Chapter0', text: 'Text0'),
            ],
            initialChapterIndex: 0,
            playbackChapterChanges: changes.stream,
            isActive: () => active,
            onChapterStreaming: (_, source) async {
              early.complete();
            },
            onChapterCompleted: (_, _, _) async {
              announcedCompletion = true;
            },
          );
      await early.future;
      converter.source!.complete();
      converter.release.complete(
        ConvertedChapterAudio(
          chapterIndex: 0,
          path: '${converter.request}/0.mp3',
          title: 'Chapter0',
        ),
      );
      changes.add(4);
      active = false;
      final result = await job;
      expect(announcedCompletion, false);
      expect(result.chapters.single.status, 'completed');
      expect(await File(result.chapters.single.outputPath!).exists(), true);
      final response = await converter.source!.request();
      expect(await response.stream.expand((bytes) => bytes).toList(), [
        1,
        2,
        3,
      ]);
      await changes.close();
      await root.delete(recursive: true);
    },
  );
}
