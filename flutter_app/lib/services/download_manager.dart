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
  final Map<String, CancelToken> _tokens = {};
  final StreamController<DownloadEvent> _events =
      StreamController<DownloadEvent>.broadcast();

  Stream<DownloadEvent> get events => _events.stream;

  void _emit(DownloadEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<File> download({
    required String jobId,
    required String url,
    required String filename,
  }) async {
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
    _tokens[path] = token;
    try {
      if (_events.isClosed) throw StateError('Download manager is disposed');
      await _dio.download(
        url,
        stagedFile.path,
        cancelToken: token,
        onReceiveProgress: (count, total) {
          if (total > 0) {
            _emit(DownloadEvent(path: path, progress: count / total));
          }
        },
      );
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
      if (identical(_tokens[path], token)) _tokens.remove(path);
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  void cancel(String path) {
    _tokens.remove(path)?.cancel();
  }

  void dispose() {
    for (final token in _tokens.values) {
      token.cancel();
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
