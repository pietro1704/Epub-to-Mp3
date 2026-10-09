import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_cache_eviction.dart';
import 'protected_audio_storage_guard.dart';

/// Minimal dio-based downloader. Persists files under
/// `<documents>/downloads/<jobId>/<filename>`. Mirrors iOS
/// `DownloadManager.swift` interface (start/cancel/progress).
class DownloadManager {
  DownloadManager({Dio? dio, ProtectedAudioStorageGuard? storageGuard})
    : _dio = dio ?? Dio(),
      _storageGuard = storageGuard ?? ProtectedAudioStorageGuard();
  final Dio _dio;
  final ProtectedAudioStorageGuard _storageGuard;
  final Map<String, Set<CancelToken>> _tokens = {};
  final StreamController<DownloadEvent> _events =
      StreamController<DownloadEvent>.broadcast();

  Stream<DownloadEvent> get events => _events.stream;

  static void _validatePathComponent(String value, String name) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      throw ArgumentError.value(value, name, 'Must be a single path component');
    }
  }

  void _emit(DownloadEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<File> download({
    required String jobId,
    required String url,
    required String filename,
  }) async {
    _validatePathComponent(jobId, 'jobId');
    _validatePathComponent(filename, 'filename');
    if (_events.isClosed) throw StateError('Download manager is disposed');
    await _storageGuard.ensureCanRetain(
      estimatedBytes: ProtectedAudioStorageGuard.estimateChapterAudioBytes(''),
    );
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/downloads/$jobId');
    if (!await folder.exists()) await folder.create(recursive: true);
    final path = '${folder.path}/$filename';
    final staging = await folder.createTemp('.download-');
    final stagedFile = File('${staging.path}/$filename');
    final token = CancelToken();
    (_tokens[path] ??= <CancelToken>{}).add(token);
    try {
      if (_events.isClosed) throw StateError('Download manager is disposed');
      final response = await _dio.download(
        url,
        stagedFile.path,
        cancelToken: token,
        onReceiveProgress: (count, total) {
          if (total > 0) {
            _emit(DownloadEvent(path: path, progress: count / total));
          }
        },
      );
      if (await stagedFile.length() == 0) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Downloaded file is empty',
        );
      }
      await stagedFile.rename(path);
      _emit(DownloadEvent(path: path, progress: 1.0, completed: true));
      // Completed downloads are protected listening content. Rebuildable
      // cache maintenance must never run against this directory.
      await OfflineCacheEviction.touchLastAccess(jobId);
      return File(path);
    } on DioException catch (e) {
      final msg = e.type == DioExceptionType.cancel
          ? 'cancelled'
          : e.message ?? e.type.name;
      _emit(DownloadEvent(path: path, progress: 0, error: msg));
      rethrow;
    } finally {
      _tokens[path]?.remove(token);
      if (_tokens[path]?.isEmpty ?? false) _tokens.remove(path);
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  void cancel(String path) {
    for (final token in _tokens.remove(path) ?? <CancelToken>{}) {
      token.cancel();
    }
  }

  void dispose() {
    for (final tokens in _tokens.values) {
      for (final token in tokens) {
        token.cancel();
      }
    }
    _tokens.clear();
    unawaited(_events.close());
  }
}

class DownloadEvent {
  const DownloadEvent({
    required this.path,
    required this.progress,
    this.completed = false,
    this.error,
  });
  final String path;
  final double progress;
  final bool completed;
  final String? error;
}
