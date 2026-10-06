import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';
import 'local_conversion_job.dart';
import 'speech_text_policy.dart';

/// Converts selected parsed chapters one at a time and persists each result.
/// The next chapter is not started until its MP3 and manifest entry are saved.
class EdgeChapterConversionService {
  EdgeChapterConversionService({
    required this.converter,
    required this.coordinator,
  });

  final EmbeddedConverter converter;
  final ConversionJobCoordinator coordinator;

  Future<LocalConversionJob> convert({
    required String bookId,
    required String jobId,
    required List<FulltextChapter> chapters,
    required String outputDirectory,
    Set<int>? selectedIndices,
    Future<void> Function(LocalConversionJob job)? onUpdate,
    Future<void> Function(
      FulltextChapter chapter,
      String outputPath,
      LocalConversionJob job,
    )? onChapterCompleted,
  }) async {
    final selected = chapters
        .where((chapter) => selectedIndices == null || selectedIndices.contains(chapter.index))
        .where((chapter) => chapter.text.trim().isNotEmpty)
        .toList();
    if (selected.isEmpty) {
      throw EmbeddedConversionFailure(
        'NO_READABLE_CHAPTERS',
        'Selected chapters have no readable text',
      );
    }

    final locale = SpeechTextPolicy.detectLocale(
      selected.map((chapter) => chapter.text),
    );
    final directory = Directory(outputDirectory);
    await directory.create(recursive: true);
    final restored = await coordinator.store.load(bookId, jobId);
    final LocalConversionJob job0;
    if (restored != null) {
      job0 = restored;
    } else {
      job0 = await coordinator.createJob(
        bookId: bookId,
        jobId: jobId,
        chapters: selected
            .map((chapter) => LocalConversionChapterSpec(chapter.index, chapter.displayTitle))
            .toList(),
      );
    }
    var job = job0;

    for (final chapter in selected) {
      if (!coordinator.pendingChapterIndices(job).contains(chapter.index)) continue;
      job = await coordinator.markChapterRunning(job, chapter.index);
      await onUpdate?.call(job);
      try {
        final filename = '${chapter.index.toString().padLeft(4, '0')}-${_safeName(chapter.displayTitle)}.mp3';
        final path = File('${directory.path}/$filename');
        Uint8List audio;
        try {
          audio = await converter.edgeProbe(chapter.text, locale: locale);
        } catch (edgeError) {
          final fallbackPath = '${path.path}.tts';
          try {
            await converter.synthesizeFallback(
              chapter.text,
              locale: locale,
              path: fallbackPath,
            );
            audio = await File(fallbackPath).readAsBytes();
            await File(fallbackPath).delete();
          } catch (fallbackError) {
            await converter.speakFallback(chapter.text, locale: locale);
            throw EmbeddedConversionFailure(
              'DIRECT_SPEECH_FALLBACK',
              'Edge failed: $edgeError; persisted fallback failed: $fallbackError',
            );
          }
        }
        final temp = File('${path.path}.part');
        await temp.writeAsBytes(audio, flush: true);
        await temp.rename(path.path);
        job = await coordinator.completeChapter(job, chapter.index, path.path);
        await _writeManifest(directory, job, selected);
        await onChapterCompleted?.call(chapter, path.path, job);
        await onUpdate?.call(job);
      } catch (error) {
        job = await coordinator.failChapter(job, chapter.index, error.toString());
        await _writeManifest(directory, job, selected);
        await onUpdate?.call(job);
        rethrow;
      }
    }
    return job;
  }

  Future<void> _writeManifest(
    Directory directory,
    LocalConversionJob job,
    List<FulltextChapter> chapters,
  ) async {
    final payload = {
      'version': 1,
      'bookId': job.bookId,
      'jobId': job.jobId,
      'status': job.status.name,
      'chapters': chapters.map((chapter) {
        final state = job.chapters.where((item) => item.index == chapter.index).firstOrNull;
        return {
          'index': chapter.index,
          'name': chapter.displayTitle,
          'status': state?.status ?? 'pending',
          if (state?.outputPath != null) 'audioPath': state!.outputPath,
          if (state?.error != null) 'error': state!.error,
        };
      }).toList(),
    };
    final target = File('${directory.path}/manifest.json');
    final temp = File('${target.path}.part');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename(target.path);
  }

  String _safeName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
    return sanitized.isEmpty ? 'Chapter' : sanitized;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
