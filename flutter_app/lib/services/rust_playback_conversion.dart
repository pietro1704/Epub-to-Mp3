import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';
import 'local_conversion_job.dart';
import 'playback_chapter_window.dart';

/// Converts only chapters in the moving Listen window through converter-ffi.
/// Chapter indices remain source positions so jobs, resume data, and FFI ranges
/// keep the same EPUB axis even when structural chapters contain no text.
class RustPlaybackConversionService {
  RustPlaybackConversionService({
    required this.converter,
    required this.coordinator,
    this.window = const PlaybackChapterWindow(),
  });

  final EmbeddedConverter converter;
  final ConversionJobCoordinator coordinator;
  final PlaybackChapterWindow window;

  Future<LocalConversionJob> convert({
    required String bookId,
    required String jobId,
    required String inputPath,
    required String outputDirectory,
    required List<FulltextChapter> chapters,
    required int initialChapterIndex,
    required Stream<int> playbackChapterChanges,
    required bool Function() isActive,
    Future<void> Function(LocalConversionJob job)? onUpdate,
    Future<void> Function(
      FulltextChapter chapter,
      String outputPath,
      LocalConversionJob job,
    )?
    onChapterCompleted,
  }) async {
    final selected = chapters
        .where((chapter) => chapter.text.trim().isNotEmpty)
        .toList();
    if (selected.isEmpty) {
      throw EmbeddedConversionFailure(
        'NO_READABLE_CHAPTERS',
        'The book has no readable chapters',
      );
    }

    var currentChapter = initialChapterIndex;
    var streamClosed = false;
    var windowChanged = Completer<void>();
    final subscription = playbackChapterChanges.listen(
      (index) {
        currentChapter = index;
        if (!windowChanged.isCompleted) windowChanged.complete();
        windowChanged = Completer<void>();
      },
      onDone: () {
        streamClosed = true;
        if (!windowChanged.isCompleted) windowChanged.complete();
      },
    );

    try {
      final root = Directory(outputDirectory);
      await root.create(recursive: true);
      final restored = await coordinator.store.load(bookId, jobId);
      final specs = selected
          .map(
            (chapter) =>
                LocalConversionChapterSpec(chapter.index, chapter.displayTitle),
          )
          .toList();
      var job =
          restored == null ||
              restored.status == LocalConversionJobStatus.cancelled
          ? await coordinator.createJob(
              bookId: bookId,
              jobId: jobId,
              chapters: specs,
            )
          : await coordinator.reconcileChapters(restored, specs);

      for (final chapter in job.chapters.where(
        (chapter) => chapter.status == 'failed',
      )) {
        job = await coordinator.retryChapter(job, chapter.index);
      }
      for (final chapter in [
        ...job.chapters.where((item) => item.status == 'completed'),
      ]) {
        final path = chapter.outputPath;
        if (path == null || !await File(path).exists()) {
          job = await coordinator.retryChapter(job, chapter.index);
        }
      }

      while (isActive() && !streamClosed) {
        final nextWindowChange = windowChanged.future;
        final pending = coordinator.pendingChapterIndices(job);
        if (pending.isEmpty &&
            job.chapters.every((chapter) => chapter.status == 'completed')) {
          break;
        }
        final chapterIndex = pending
            .where((index) => window.contains(currentChapter, index))
            .firstOrNull;
        if (chapterIndex == null) {
          await nextWindowChange;
          continue;
        }

        final chapter = selected.firstWhere(
          (item) => item.index == chapterIndex,
        );
        final chapterDirectory = Directory(
          '${root.path}/streaming/chapter_$chapterIndex',
        );
        if (await chapterDirectory.exists()) {
          await chapterDirectory.delete(recursive: true);
        }
        await chapterDirectory.create(recursive: true);

        job = await coordinator.markChapterRunning(job, chapterIndex);
        await _writeManifest(root, job, selected);
        await onUpdate?.call(job);

        try {
          final result = await converter.convertChapter(
            inputPath: inputPath,
            outputPath: chapterDirectory.path,
            chapterIndex: chapterIndex,
          );
          final audio = File(result.path);
          if (!await audio.exists() || await audio.length() == 0) {
            throw EmbeddedConversionFailure(
              'INVALID_CHAPTER_AUDIO',
              'Rust returned a missing or empty chapter file',
            );
          }
          if (!isActive() || !window.contains(currentChapter, chapterIndex)) {
            await chapterDirectory.delete(recursive: true);
            job = await coordinator.retryChapter(job, chapterIndex);
            await _writeManifest(root, job, selected);
            continue;
          }

          job = await coordinator.completeChapter(
            job,
            chapterIndex,
            audio.path,
          );
          await _writeManifest(root, job, selected);
          await onChapterCompleted?.call(chapter, audio.path, job);
          await onUpdate?.call(job);
        } catch (error) {
          job = await coordinator.failChapter(
            job,
            chapterIndex,
            error.toString(),
          );
          await _writeManifest(root, job, selected);
          await onUpdate?.call(job);
          rethrow;
        }
      }
      if ((streamClosed || !isActive()) &&
          job.status == LocalConversionJobStatus.running) {
        job = await coordinator.suspend(job);
        await _writeManifest(root, job, selected);
      }
      return job;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _writeManifest(
    Directory root,
    LocalConversionJob job,
    List<FulltextChapter> chapters,
  ) async {
    final payload = {
      'version': 1,
      'bookId': job.bookId,
      'jobId': job.jobId,
      'status': job.status.name,
      'chapters': chapters.map((chapter) {
        final state = job.chapters
            .where((item) => item.index == chapter.index)
            .firstOrNull;
        return {
          'index': chapter.index,
          'name': chapter.displayTitle,
          'status': state?.status ?? 'pending',
          if (state?.outputPath != null) 'audioPath': state!.outputPath,
          if (state?.error != null) 'error': state!.error,
        };
      }).toList(),
    };
    final target = File('${root.path}/manifest.json');
    final temp = File('${target.path}.part');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename(target.path);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
