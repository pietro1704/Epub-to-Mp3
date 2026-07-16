import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum LocalConversionJobStatus { pending, running, completed, failed, cancelled }

class LocalConversionChapterSpec {
  const LocalConversionChapterSpec(this.index, this.name);
  final int index;
  final String name;
}

class LocalConversionChapter {
  const LocalConversionChapter({
    required this.index,
    required this.name,
    this.status = 'pending',
    this.outputPath,
    this.error,
    this.updatedAt,
  });

  final int index;
  final String name;
  final String status;
  final String? outputPath;
  final String? error;
  final DateTime? updatedAt;

  LocalConversionChapter copyWith({
    String? status,
    String? outputPath,
    String? error,
    DateTime? updatedAt,
    bool clearError = false,
  }) => LocalConversionChapter(
        index: index,
        name: name,
        status: status ?? this.status,
        outputPath: outputPath ?? this.outputPath,
        error: clearError ? null : (error ?? this.error),
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'status': status,
        if (outputPath != null) 'outputPath': outputPath,
        if (error != null) 'error': error,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  factory LocalConversionChapter.fromJson(Map<String, dynamic> json) =>
      LocalConversionChapter(
        index: json['index'] as int,
        name: json['name'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
        outputPath: json['outputPath'] as String?,
        error: json['error'] as String?,
        updatedAt: _date(json['updatedAt']),
      );
}

class LocalConversionJob {
  const LocalConversionJob({
    required this.bookId,
    required this.jobId,
    required this.chapters,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.currentChapterIndex,
    this.completedOutputs = const [],
    this.error,
    this.lastActivityAt,
  });

  final String bookId;
  final String jobId;
  final List<LocalConversionChapter> chapters;
  final LocalConversionJobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? currentChapterIndex;
  final List<String> completedOutputs;
  final String? error;
  final DateTime? lastActivityAt;

  LocalConversionJob copyWith({
    List<LocalConversionChapter>? chapters,
    LocalConversionJobStatus? status,
    DateTime? updatedAt,
    int? currentChapterIndex,
    List<String>? completedOutputs,
    String? error,
    DateTime? lastActivityAt,
    bool clearError = false,
  }) => LocalConversionJob(
        bookId: bookId,
        jobId: jobId,
        chapters: chapters ?? this.chapters,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
        completedOutputs: completedOutputs ?? this.completedOutputs,
        error: clearError ? null : (error ?? this.error),
        lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      );

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'jobId': jobId,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (currentChapterIndex != null) 'currentChapterIndex': currentChapterIndex,
        'completedOutputs': completedOutputs,
        if (error != null) 'error': error,
        if (lastActivityAt != null) 'lastActivityAt': lastActivityAt!.toIso8601String(),
      };

  factory LocalConversionJob.fromJson(Map<String, dynamic> json) => LocalConversionJob(
        bookId: json['bookId'] as String,
        jobId: json['jobId'] as String,
        chapters: (json['chapters'] as List<dynamic>)
            .map((c) => LocalConversionChapter.fromJson(c as Map<String, dynamic>))
            .toList(),
        status: LocalConversionJobStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => LocalConversionJobStatus.pending,
        ),
        createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
        updatedAt: _date(json['updatedAt']) ?? DateTime.now().toUtc(),
        currentChapterIndex: json['currentChapterIndex'] as int?,
        completedOutputs: (json['completedOutputs'] as List<dynamic>? ?? const []).cast<String>(),
        error: json['error'] as String?,
        lastActivityAt: _date(json['lastActivityAt']),
      );
}

DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value as String);

class LocalConversionJobStore {
  LocalConversionJobStore(this._prefs, {this.prefix = 'local-conversion.v1'});
  final SharedPreferences _prefs;
  final String prefix;

  String key(String bookId, String jobId) => '$prefix:$bookId:$jobId';

  Future<LocalConversionJob?> load(String bookId, String jobId) async {
    final raw = _prefs.getString(key(bookId, jobId));
    if (raw == null) return null;
    try {
      return LocalConversionJob.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocalConversionJob job) async {
    await _prefs.setString(key(job.bookId, job.jobId), jsonEncode(job.toJson()));
  }
}

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
  }) async {
    final now = _now();
    final job = LocalConversionJob(
      bookId: bookId,
      jobId: jobId,
      chapters: chapters.map((c) => LocalConversionChapter(index: c.index, name: c.name)).toList(),
      status: LocalConversionJobStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    await store.save(job);
    return job;
  }

  List<int> pendingChapterIndices(LocalConversionJob job) => job.chapters
      .where((c) => c.status == 'pending')
      .map((c) => c.index)
      .toList();

  Future<LocalConversionJob> markChapterRunning(LocalConversionJob job, int index) =>
      _updateChapter(job, index, (c, now) => c.copyWith(status: 'running', updatedAt: now, clearError: true),
          status: LocalConversionJobStatus.running);

  Future<LocalConversionJob> completeChapter(LocalConversionJob job, int index, String outputPath) =>
      _updateChapter(job, index, (c, now) => c.copyWith(status: 'completed', outputPath: outputPath, updatedAt: now, clearError: true),
          status: job.chapters.every((c) => c.index == index || c.status == 'completed')
              ? LocalConversionJobStatus.completed
              : LocalConversionJobStatus.running,
          outputPath: outputPath);

  Future<LocalConversionJob> failChapter(LocalConversionJob job, int index, String error) =>
      _updateChapter(job, index, (c, now) => c.copyWith(status: 'failed', error: error, updatedAt: now),
          status: LocalConversionJobStatus.failed, error: error);

  Future<LocalConversionJob> retryChapter(LocalConversionJob job, int index) =>
      _updateChapter(job, index, (c, now) => c.copyWith(status: 'pending', updatedAt: now, clearError: true),
          status: LocalConversionJobStatus.pending, clearError: true);

  Future<LocalConversionJob> cancel(LocalConversionJob job) => _persist(
        job.copyWith(status: LocalConversionJobStatus.cancelled, updatedAt: _now()),
      );

  Future<LocalConversionJob> watchdog(LocalConversionJob job) async {
    final last = job.lastActivityAt ?? job.updatedAt;
    if (job.status != LocalConversionJobStatus.running || _now().difference(last) < watchdogTimeout) return job;
    final index = job.currentChapterIndex;
    if (index == null) return job;
    return failChapter(job, index, 'Conversion timed out after ${watchdogTimeout.inMinutes} minutes');
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
    final chapters = job.chapters.map((c) => c.index == index ? update(c, now) : c).toList();
    final outputs = [...job.completedOutputs];
    if (outputPath != null && !outputs.contains(outputPath)) outputs.add(outputPath);
    return _persist(job.copyWith(
      chapters: chapters,
      status: status,
      updatedAt: now,
      currentChapterIndex: index,
      completedOutputs: outputs,
      error: error,
      clearError: clearError,
      lastActivityAt: now,
    ));
  }

  Future<LocalConversionJob> _persist(LocalConversionJob job) async {
    await store.save(job);
    return job;
  }
}