import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Minimal dio-based downloader. Persists files under
/// `<documents>/downloads/<jobId>/<filename>`. Mirrors iOS
/// `DownloadManager.swift` interface (start/cancel/progress).
class DownloadManager {
  DownloadManager({Dio? dio}) : _dio = dio ?? Dio();
  final Dio _dio;
  final Map<String, CancelToken> _tokens = {};
  final StreamController<DownloadEvent> _events =
      StreamController<DownloadEvent>.broadcast();

  Stream<DownloadEvent> get events => _events.stream;

  Future<File> download({
    required String jobId,
    required String url,
    required String filename,
  }) async {
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
      return File(path);
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
  });
  final String path;
  final double progress;
  final bool completed;
}
