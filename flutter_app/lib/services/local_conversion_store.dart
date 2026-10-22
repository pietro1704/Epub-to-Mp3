import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tts_preferences.dart';
import 'local_conversion_record.dart';

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
    final saved = await _prefs.setString(
      key(job.bookId, job.jobId),
      jsonEncode(job.toJson()),
    );
    if (!saved) throw StateError('Could not persist local conversion history');
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
      mode: 'manual',
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
