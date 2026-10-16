import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';
import 'local_conversion_job.dart';
import '../models/tts_preferences.dart';
import 'playback_chapter_window.dart';
import 'growing_chapter_audio_source.dart';

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
  Future<void> Function()? _cancelCurrent;
  Future<void> cancel() async {
    await _cancelCurrent?.call();
  }

  Future<LocalConversionJob> convert({
    String? optionsJson,
    Future<void> Function(List<TtsSelection>)? onSecondaryUsed,
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
    Future<void> Function(
      FulltextChapter chapter,
      GrowingChapterAudioSource source,
    )?
    onChapterStreaming,
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
    var cancelledByOwner = false;
    String? activeNativeRequest;
    int? activeNativeChapter;
    var activeRequestStreams = false;
    Future<void> cancelActiveConversion() async {
      final request = activeNativeRequest;
      if (request != null &&
          activeRequestStreams &&
          converter is StreamingChapterConverter) {
        await (converter as StreamingChapterConverter).cancelStreamingChapter(
          request,
        );
      } else if (request != null && converter is CancellableEmbeddedConverter) {
        await (converter as CancellableEmbeddedConverter).cancelConversion(
          outputPath: request,
        );
      }
    }

    var windowChanged = Completer<void>();
    _cancelCurrent = () async {
      cancelledByOwner = true;
      if (!windowChanged.isCompleted) windowChanged.complete();
      await cancelActiveConversion();
    };
    final subscription = playbackChapterChanges.listen(
      (index) {
        currentChapter = index;
        if (activeNativeChapter != null &&
            !window.contains(index, activeNativeChapter)) {
          unawaited(cancelActiveConversion());
        }
        if (!windowChanged.isCompleted) windowChanged.complete();
        windowChanged = Completer<void>();
      },
      onDone: () {
        streamClosed = true;
        unawaited(cancelActiveConversion());
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
              conversionOptionsJson:
                  optionsJson ?? const TtsPreferences().optionsJson(),
            )
          : await coordinator.reconcileChapters(restored, specs);

      if (job.conversionOptionsJson == null) {
        if (job.completedOutputs.isNotEmpty ||
            job.chapters.any((chapter) => chapter.status == 'completed')) {
          throw EmbeddedConversionFailure(
            'RESUME_VOICE_UNKNOWN',
            'This older conversion has no recorded voice. Start a new conversion to avoid mixing narration voices.',
          );
        }
        job = job.copyWith(
          conversionOptionsJson:
              optionsJson ?? const TtsPreferences().optionsJson(),
        );
        await coordinator.store.save(job);
      }
      final captured = Map<String, dynamic>.from(
        jsonDecode(job.conversionOptionsJson!) as Map,
      );
      if (optionsJson != null) {
        final currentPaths = Map<String, dynamic>.from(
          jsonDecode(optionsJson) as Map,
        );
        for (final key in ['models_root', 'espeak_data_directory']) {
          if (currentPaths[key] != null) captured[key] = currentPaths[key];
        }
      }
      final capturedOptionsJson = jsonEncode(captured);
      if (capturedOptionsJson != job.conversionOptionsJson) {
        job = job.copyWith(conversionOptionsJson: capturedOptionsJson);
        await coordinator.store.save(job);
      }

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

      while (isActive() && !streamClosed && !cancelledByOwner) {
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
          '${root.path}/streaming/chapter_${chapterIndex}_${DateTime.now().microsecondsSinceEpoch}',
        );
        if (await chapterDirectory.exists()) {
          await chapterDirectory.delete(recursive: true);
        }
        await chapterDirectory.create(recursive: true);

        job = await coordinator.markChapterRunning(job, chapterIndex);
        await _writeManifest(root, job, selected);
        await onUpdate?.call(job);

        var deliveredStreamSource = false;
        try {
          final streaming =
              converter is StreamingChapterConverter &&
              onChapterStreaming != null;
          activeRequestStreams = streaming;
          activeNativeRequest = chapterDirectory.path;
          activeNativeChapter = chapterIndex;
          final chapterOptions = Map<String, dynamic>.from(
            jsonDecode(capturedOptionsJson) as Map,
          );
          if (job.ttsPolicyState != null) {
            chapterOptions['tts_policy_state'] = job.ttsPolicyState;
          }
          final chapterOptionsJson = jsonEncode(chapterOptions);
          final result = streaming
              ? await (converter as StreamingChapterConverter).streamChapter(
                  inputPath: inputPath,
                  outputPath: chapterDirectory.path,
                  chapterIndex: chapterIndex,
                  optionsJson: chapterOptionsJson,
                  onFirstAudio: (source) async {
                    if (!isActive() ||
                        cancelledByOwner ||
                        !window.contains(currentChapter, chapterIndex)) {
                      source.fail(
                        StateError('Chapter left the playback window'),
                      );
                      await cancelActiveConversion();
                      return;
                    }
                    await onChapterStreaming(chapter, source);
                    deliveredStreamSource = true;
                  },
                )
              : await converter.convertChapter(
                  inputPath: inputPath,
                  outputPath: chapterDirectory.path,
                  chapterIndex: chapterIndex,
                  optionsJson: chapterOptionsJson,
                );
          activeNativeRequest = null;
          activeNativeChapter = null;
          if (result.ttsPolicyState != null) {
            job = job.copyWith(ttsPolicyState: result.ttsPolicyState);
            await coordinator.store.save(job);
          }
          if (!job.fallbackNoticeShown &&
              onSecondaryUsed != null &&
              result.fallbackUsed) {
            await onSecondaryUsed(result.usedSelections);
            job = job.copyWith(fallbackNoticeShown: true);
            await coordinator.store.save(job);
          }
          final audio = File(result.path);
          if (!await audio.exists() || await audio.length() == 0) {
            throw EmbeddedConversionFailure(
              'INVALID_CHAPTER_AUDIO',
              'Rust returned a missing or empty chapter file',
            );
          }
          if (!isActive() ||
              cancelledByOwner ||
              !window.contains(currentChapter, chapterIndex)) {
            if (deliveredStreamSource) {
              // A queued live source may still serve immutable files through
              // its existing HTTP request after the playback window moves.
              job = await coordinator.completeChapter(
                job,
                chapterIndex,
                audio.path,
                usedSelections: result.usedSelections,
                fallbackUsed: result.fallbackUsed,
              );
            } else {
              await chapterDirectory.delete(recursive: true);
              job = await coordinator.retryChapter(job, chapterIndex);
            }
            await _writeManifest(root, job, selected);
            continue;
          }

          job = await coordinator.completeChapter(
            job,
            chapterIndex,
            audio.path,
            usedSelections: result.usedSelections,
            fallbackUsed: result.fallbackUsed,
          );
          await _writeManifest(root, job, selected);
          await onChapterCompleted?.call(chapter, audio.path, job);
          await onUpdate?.call(job);
        } catch (error) {
          activeNativeRequest = null;
          activeNativeChapter = null;
          if (streamingCancelledByWindow(
            streamClosed || cancelledByOwner,
            isActive(),
            window.contains(currentChapter, chapterIndex),
          )) {
            job = await coordinator.retryChapter(job, chapterIndex);
            if (await chapterDirectory.exists()) {
              await chapterDirectory.delete(recursive: true);
            }
            await onUpdate?.call(job);
            continue;
          }
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
      if ((streamClosed || cancelledByOwner || !isActive()) &&
          job.status == LocalConversionJobStatus.running) {
        job = await coordinator.suspend(job);
        await _writeManifest(root, job, selected);
      }
      return job;
    } finally {
      await cancelActiveConversion();
      await subscription.cancel();
      _cancelCurrent = null;
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
      'conversionOptionsJson': ?job.conversionOptionsJson,
      'ttsPolicyState': ?job.ttsPolicyState,
      'usedSelections': job.usedSelections
          .map((selection) => selection.toJson())
          .toList(),
      'fallbackNoticeShown': job.fallbackNoticeShown,
      'fallbackUsed': job.fallbackUsed,
      'chapters': chapters.map((chapter) {
        final state = job.chapters
            .where((item) => item.index == chapter.index)
            .firstOrNull;
        return {
          'index': chapter.index,
          'name': chapter.displayTitle,
          'status': state?.status ?? 'pending',
          'fallbackUsed': state?.fallbackUsed ?? false,
          'usedSelections':
              state?.usedSelections
                  .map((selection) => selection.toJson())
                  .toList() ??
              [],
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

bool streamingCancelledByWindow(
  bool streamClosed,
  bool active,
  bool insideWindow,
) => streamClosed || !active || !insideWindow;

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
