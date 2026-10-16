import 'dart:convert';
import 'dart:io';
import '../models/tts_preferences.dart';

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
    this.usedSelections = const [],
    this.fallbackUsed = false,
  });

  final List<TtsSelection> usedSelections;
  final bool fallbackUsed;
  final int index;
  final String name;
  final String status;
  final String? outputPath;
  final String? error;
  final DateTime? updatedAt;

  LocalConversionChapter copyWith({
    List<TtsSelection>? usedSelections,
    bool? fallbackUsed,
    String? status,
    String? outputPath,
    String? error,
    DateTime? updatedAt,
    bool clearError = false,
  }) => LocalConversionChapter(
    usedSelections: usedSelections ?? this.usedSelections,
    fallbackUsed: fallbackUsed ?? this.fallbackUsed,
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
    'usedSelections': usedSelections
        .map((selection) => selection.toJson())
        .toList(),
    'fallbackUsed': fallbackUsed,
    'status': status,
    if (outputPath != null) 'outputPath': outputPath,
    if (error != null) 'error': error,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  factory LocalConversionChapter.fromJson(Map<String, dynamic> json) =>
      LocalConversionChapter(
        usedSelections: (json['usedSelections'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (value) =>
                  TtsSelection.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(),
        fallbackUsed: json['fallbackUsed'] == true,
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
    this.bookTitle,
    this.manifestUsedSelections = const [],
    this.manifestFallbackUsed = false,
    this.conversionOptionsJson,
    this.ttsPolicyState,
    this.fallbackNoticeShown = false,
    this.currentChapterIndex,
    this.completedOutputs = const [],
    this.error,
    this.lastActivityAt,
  });

  final String bookId;
  final String jobId;
  final String? bookTitle;
  final List<TtsSelection> manifestUsedSelections;
  final bool manifestFallbackUsed;
  final List<LocalConversionChapter> chapters;
  final LocalConversionJobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? conversionOptionsJson;
  final Map<String, dynamic>? ttsPolicyState;
  final bool fallbackNoticeShown;
  bool get fallbackUsed =>
      manifestFallbackUsed || chapters.any((chapter) => chapter.fallbackUsed);
  List<TtsSelection> get usedSelections {
    final unique = <String, TtsSelection>{};
    for (final selection in manifestUsedSelections) {
      unique[jsonEncode(selection.toJson())] = selection;
    }
    for (final chapter in chapters) {
      for (final selection in chapter.usedSelections) {
        unique[jsonEncode(selection.toJson())] = selection;
      }
    }
    return unique.values.toList(growable: false);
  }

  final int? currentChapterIndex;
  final List<String> completedOutputs;
  final String? error;
  final DateTime? lastActivityAt;

  LocalConversionJob copyWith({
    String? conversionOptionsJson,
    Map<String, dynamic>? ttsPolicyState,
    bool? fallbackNoticeShown,
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
    bookTitle: bookTitle,
    manifestUsedSelections: manifestUsedSelections,
    manifestFallbackUsed: manifestFallbackUsed,
    conversionOptionsJson: conversionOptionsJson ?? this.conversionOptionsJson,
    ttsPolicyState: ttsPolicyState ?? this.ttsPolicyState,
    fallbackNoticeShown: fallbackNoticeShown ?? this.fallbackNoticeShown,
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
    'bookTitle': ?bookTitle,
    if (manifestUsedSelections.isNotEmpty)
      'manifestUsedSelections': manifestUsedSelections
          .map((selection) => selection.toJson())
          .toList(),
    if (manifestFallbackUsed) 'manifestFallbackUsed': true,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (currentChapterIndex != null) 'currentChapterIndex': currentChapterIndex,
    'completedOutputs': completedOutputs,
    'conversionOptionsJson': ?conversionOptionsJson,
    'ttsPolicyState': ?ttsPolicyState,
    'fallbackNoticeShown': fallbackNoticeShown,
    'fallbackUsed': fallbackUsed,
    if (error != null) 'error': error,
    if (lastActivityAt != null)
      'lastActivityAt': lastActivityAt!.toIso8601String(),
  };

  factory LocalConversionJob.fromJson(
    Map<String, dynamic> json,
  ) => LocalConversionJob(
    ttsPolicyState: json['ttsPolicyState'] is Map
        ? Map<String, dynamic>.from(json['ttsPolicyState'] as Map)
        : null,
    fallbackNoticeShown: json['fallbackNoticeShown'] == true,
    conversionOptionsJson:
        json['conversionOptionsJson'] as String? ??
        _legacyConversionOptions(json),
    bookId: json['bookId'] as String,
    jobId: json['jobId'] as String,
    bookTitle: json['bookTitle'] as String?,
    manifestUsedSelections: (json['manifestUsedSelections'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => TtsSelection.fromJson(Map<String, dynamic>.from(value)))
        .toList(),
    manifestFallbackUsed: json['manifestFallbackUsed'] == true,
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
    completedOutputs: (json['completedOutputs'] as List<dynamic>? ?? const [])
        .cast<String>(),
    error: json['error'] as String?,
    lastActivityAt: _date(json['lastActivityAt']),
  );
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value as String);

class LocalConversionHistory {
  const LocalConversionHistory({
    required this.jobs,
    required this.unreadableKeys,
  });

  final List<LocalConversionJob> jobs;
  final List<String> unreadableKeys;
}

class LocalConversionJobStore {
  LocalConversionJobStore(this._prefs, {this.prefix = 'local-conversion.v1'});
  final SharedPreferences _prefs;
  final String prefix;

  String key(String bookId, String jobId) => '$prefix:$bookId:$jobId';

  /// Reads the existing per-job records without migrating or deleting them.
  /// Damaged entries remain on disk and are reported alongside usable history.
  Future<LocalConversionHistory> loadHistory() async {
    await _prefs.reload();
    final jobs = <LocalConversionJob>[];
    final unreadableKeys = <String>[];
    final keys =
        _prefs.getKeys().where((key) => key.startsWith('$prefix:')).toList()
          ..sort();
    for (final key in keys) {
      try {
        final raw = _prefs.getString(key);
        if (raw == null) throw const FormatException('Missing job record');
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (!LocalConversionJobStatus.values.any(
          (status) => status.name == decoded['status'],
        )) {
          throw const FormatException('Unknown recorded job status');
        }
        for (final field in ['createdAt', 'updatedAt']) {
          final value = decoded[field];
          if (value is! String || DateTime.tryParse(value) == null) {
            throw FormatException('Invalid recorded job timestamp: $field');
          }
        }
        final job = LocalConversionJob.fromJson(decoded);
        if (job.bookId.isEmpty ||
            job.jobId.isEmpty ||
            key != this.key(job.bookId, job.jobId)) {
          throw const FormatException('Job record identity mismatch');
        }
        jobs.add(job);
      } catch (_) {
        unreadableKeys.add(key);
      }
    }
    jobs.sort((left, right) {
      final byDate = right.updatedAt.compareTo(left.updatedAt);
      return byDate != 0 ? byDate : left.jobId.compareTo(right.jobId);
    });
    return LocalConversionHistory(
      jobs: List.unmodifiable(jobs),
      unreadableKeys: List.unmodifiable(unreadableKeys),
    );
  }

  Future<LocalConversionJob?> load(String bookId, String jobId) async {
    final raw = _prefs.getString(key(bookId, jobId));
    if (raw == null) return null;
    try {
      return LocalConversionJob.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocalConversionJob job) async {
    await _prefs.setString(
      key(job.bookId, job.jobId),
      jsonEncode(job.toJson()),
    );
  }

  /// Projects a completed Rust manifest into local history. A legacy injected
  /// job ID alone is not enough evidence to fabricate a conversion record.
  Future<LocalConversionJob> saveCompletedManifest({
    required Map<String, dynamic> manifest,
    required String bookId,
    required DateTime startedAt,
    String? outputDirectory,
    String? conversionOptionsJson,
  }) async {
    final jobId = manifest['jobId'];
    final entries = manifest['chapters'];
    if (bookId.isEmpty ||
        jobId is! String ||
        jobId.isEmpty ||
        entries is! List ||
        entries.isEmpty) {
      throw const FormatException('Invalid completed Rust manifest');
    }
    final now = DateTime.now().toUtc();
    final used = (manifest['usedSelections'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => TtsSelection.fromJson(Map<String, dynamic>.from(value)))
        .toList(growable: false);
    final establishedRoot = outputDirectory != null && Directory(outputDirectory).isAbsolute
        ? outputDirectory
        : null;
    final sourceIndices = <int>{};
    final chapters = entries
        .map((value) {
          final entry = Map<String, dynamic>.from(value as Map);
          final index = entry['sourceIndex'];
          if (index is! int || index < 0 || !sourceIndices.add(index)) {
            throw const FormatException(
              'Rust manifest has no source chapter index',
            );
          }
          final filename = entry['filename'];
          // A manifest filename is not an absolute audio path. Only the native
          // request establishes its output directory, and filenames cannot escape it.
          final outputPath =
              establishedRoot != null &&
                  filename is String &&
                  filename.isNotEmpty &&
                  filename != '.' &&
                  filename != '..' &&
                  !filename.contains('/') &&
                  !filename.contains('\\')
              ? Uri.directory(
                  establishedRoot,
                ).resolveUri(Uri(pathSegments: [filename])).toFilePath()
              : null;
          return LocalConversionChapter(
            index: index,
            name: entry['title'] as String? ?? '',
            status: 'completed',
            outputPath: outputPath,
            updatedAt: now,
          );
        })
        .toList(growable: false);
    final job = LocalConversionJob(
      bookId: bookId,
      jobId: jobId,
      bookTitle: manifest['title'] as String?,
      manifestUsedSelections: used,
      manifestFallbackUsed: manifest['fallbackUsed'] == true,
      chapters: chapters,
      status: LocalConversionJobStatus.completed,
      createdAt: startedAt,
      updatedAt: now,
      conversionOptionsJson: conversionOptionsJson,
      ttsPolicyState: manifest['ttsPolicyState'] is Map
          ? Map<String, dynamic>.from(manifest['ttsPolicyState'] as Map)
          : null,
      completedOutputs: chapters
          .map((chapter) => chapter.outputPath)
          .whereType<String>()
          .toList(),
    );
    final saved = await _prefs.setString(
      key(job.bookId, job.jobId),
      jsonEncode(job.toJson()),
    );
    if (!saved) throw StateError('Could not persist completed conversion history');
    return job;
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
    String? conversionOptionsJson,
  }) async {
    final now = _now();
    final job = LocalConversionJob(
      bookId: bookId,
      jobId: jobId,
      conversionOptionsJson:
          conversionOptionsJson ?? const TtsPreferences().optionsJson(),
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
  }) => _updateChapter(
    job,
    index,
    (c, now) => c.copyWith(
      status: 'completed',
      usedSelections: usedSelections,
      fallbackUsed: fallbackUsed,
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

/// Only migrate a legacy voice when its identity is actually recorded.
String? _legacyConversionOptions(Map<String, dynamic> json) {
  final engine = json['engine'];
  final voice = json['voice'];
  final model = json['model_id'] ?? json['modelId'];
  if ((engine == 'edge' && voice is String && voice.isNotEmpty) ||
      (engine == 'piper' && model is String && model.isNotEmpty)) {
    return jsonEncode({
      'tts_preferences': {
        'primary': {
          'engine': engine,
          'model_id': engine == 'piper' ? model : null,
          'voice': engine == 'edge' ? voice : null,
        },
        'secondary': null,
        'allow_online_fallback': false,
      },
      if (json['language'] != null) 'language': json['language'],
    });
  }
  return null;
}
