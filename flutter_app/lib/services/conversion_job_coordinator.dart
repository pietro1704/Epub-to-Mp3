import '../models/tts_preferences.dart';
import 'local_conversion_record.dart';
import 'local_conversion_store.dart';

class ConversionJobCoordinator {
  ConversionJobCoordinator(
    this.store, {
    DateTime Function()? now,
    this.watchdogTimeout = const Duration(minutes: 30),
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final LocalConversionJobStore store;
  final DateTime Function() _now;
  final Duration watchdogTimeout;

  Future<LocalConversionJob> createJob({
    required String bookId,
    required String jobId,
    required List<LocalConversionChapterSpec> chapters,
    String? conversionOptionsJson,
  }) async {
    final now = _now();
    final job = LocalConversionJob(
      bookId: bookId,
      jobId: jobId,
      conversionOptionsJson:
          conversionOptionsJson ?? const TtsPreferences.appDefaults().optionsJson(),
      chapters: chapters
          .map((c) => LocalConversionChapter(index: c.index, name: c.name))
          .toList(),
      status: LocalConversionJobStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    await store.save(job);
    return job;
  }

  Future<LocalConversionJob> reconcileChapters(
    LocalConversionJob job,
    List<LocalConversionChapterSpec> chapters,
  ) async {
    final existingByIndex = {
      for (final chapter in job.chapters) chapter.index: chapter,
    };
    final reconciled = chapters.map((spec) {
      final existing = existingByIndex[spec.index];
      if (existing == null || existing.name != spec.name) {
        return LocalConversionChapter(index: spec.index, name: spec.name);
      }
      return existing;
    }).toList();
    final unchanged =
        job.chapters.length == reconciled.length &&
        List.generate(reconciled.length, (index) => index).every(
          (index) =>
              job.chapters[index].index == reconciled[index].index &&
              job.chapters[index].name == reconciled[index].name,
        );
    if (unchanged) return job;

    final status = reconciled.every((chapter) => chapter.status == 'completed')
        ? LocalConversionJobStatus.completed
        : reconciled.any((chapter) => chapter.status == 'failed')
        ? LocalConversionJobStatus.failed
        : reconciled.any((chapter) => chapter.status == 'running')
        ? LocalConversionJobStatus.running
        : LocalConversionJobStatus.pending;
    return _persist(
      job.copyWith(
        chapters: reconciled,
        status: status,
        updatedAt: _now(),
        completedOutputs: reconciled
            .where((chapter) => chapter.status == 'completed')
            .map((chapter) => chapter.outputPath)
            .whereType<String>()
            .toList(),
      ),
    );
  }

  List<int> pendingChapterIndices(LocalConversionJob job) => job.chapters
      .where((c) => c.status == 'pending')
      .map((c) => c.index)
      .toList();

  Future<LocalConversionJob> markChapterRunning(
    LocalConversionJob job,
    int index,
  ) => _updateChapter(
    job,
    index,
    (c, now) => c.copyWith(status: 'running', updatedAt: now, clearError: true),
    status: LocalConversionJobStatus.running,
  );

  Future<LocalConversionJob> completeChapter(
    LocalConversionJob job,
    int index,
    String outputPath, {
    List<TtsSelection> usedSelections = const [],
    bool fallbackUsed = false,
    int textOffset = 0,
  }) => _updateChapter(
    job,
    index,
    (c, now) => c.copyWith(
      status: 'completed',
      usedSelections: usedSelections,
      fallbackUsed: fallbackUsed,
      textOffset: textOffset,
      outputPath: outputPath,
      updatedAt: now,
      clearError: true,
    ),
    status:
        job.chapters.every((c) => c.index == index || c.status == 'completed')
        ? LocalConversionJobStatus.completed
        : LocalConversionJobStatus.running,
    outputPath: outputPath,
  );

  Future<LocalConversionJob> failChapter(
    LocalConversionJob job,
    int index,
    String error,
  ) => _updateChapter(
    job,
    index,
    (c, now) => c.copyWith(status: 'failed', error: error, updatedAt: now),
    status: LocalConversionJobStatus.failed,
    error: error,
  );

  Future<LocalConversionJob> retryChapter(LocalConversionJob job, int index) =>
      _updateChapter(
        job,
        index,
        (c, now) =>
            c.copyWith(status: 'pending', updatedAt: now, clearError: true),
        status: LocalConversionJobStatus.pending,
        clearError: true,
      );

  Future<LocalConversionJob> cancel(LocalConversionJob job) => _persist(
    job.copyWith(status: LocalConversionJobStatus.cancelled, updatedAt: _now()),
  );

  Future<LocalConversionJob> suspend(LocalConversionJob job) => _persist(
    job.copyWith(
      status: LocalConversionJobStatus.pending,
      updatedAt: _now(),
      lastActivityAt: _now(),
    ),
  );

  Future<LocalConversionJob> watchdog(LocalConversionJob job) async {
    final last = job.lastActivityAt ?? job.updatedAt;
    if (job.status != LocalConversionJobStatus.running ||
        _now().difference(last) < watchdogTimeout) {
      return job;
    }
    final index = job.currentChapterIndex;
    if (index == null) return job;
    return failChapter(
      job,
      index,
      'Conversion timed out after ${watchdogTimeout.inMinutes} minutes',
    );
  }

  Future<LocalConversionJob> _updateChapter(
    LocalConversionJob job,
    int index,
    LocalConversionChapter Function(LocalConversionChapter, DateTime) update, {
    required LocalConversionJobStatus status,
    String? outputPath,
    String? error,
    bool clearError = false,
  }) async {
    final now = _now();
    final chapters = job.chapters
        .map((c) => c.index == index ? update(c, now) : c)
        .toList();
    final outputs = [...job.completedOutputs];
    if (outputPath != null && !outputs.contains(outputPath)) {
      outputs.add(outputPath);
    }
    return _persist(
      job.copyWith(
        chapters: chapters,
        status: status,
        updatedAt: now,
        currentChapterIndex: index,
        completedOutputs: outputs,
        error: error,
        clearError: clearError,
        lastActivityAt: now,
      ),
    );
  }

  Future<LocalConversionJob> _persist(LocalConversionJob job) async {
    await store.save(job);
    return job;
  }
}
