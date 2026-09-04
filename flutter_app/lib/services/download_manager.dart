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

  Future<File> download({
    required String jobId,
    required String url,
    required String filename,
  }) async {
    await _storageGuard.ensureCanRetain(
      estimatedBytes: ProtectedAudioStorageGuard.estimateChapterAudioBytes(''),
    );
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/downloads/$jobId');
    if (!await folder.exists()) await folder.create(recursive: true);
    final path = '${folder.path}/$filename';
    final token = CancelToken();
    _tokens[path] = token;
    try {
      await _dio.download(
        url,
        path,
        cancelToken: token,
        onReceiveProgress: (count, total) {
          if (total > 0) {
            _events.add(DownloadEvent(path: path, progress: count / total));
          }
        },
      );
      _events.add(DownloadEvent(path: path, progress: 1.0, completed: true));
      // After each completed download, run LRU+TTL eviction in the background.
      // Exclude the current jobId so we never immediately evict what we just
      // downloaded.
      unawaited(OfflineCacheEviction.runEviction(activeJobIds: {jobId}));
      return File(path);
    } on DioException catch (e) {
      final partial = File(path);
      if (await partial.exists()) await partial.delete();
      final msg = e.type == DioExceptionType.cancel
          ? 'cancelled'
          : e.message ?? e.type.name;
      _events.add(DownloadEvent(path: path, progress: 0, error: msg));
      rethrow;
    } finally {
      _tokens.remove(path);
    }
  }

  void cancel(String path) {
    _tokens.remove(path)?.cancel();
  }

  void dispose() => _events.close();
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
