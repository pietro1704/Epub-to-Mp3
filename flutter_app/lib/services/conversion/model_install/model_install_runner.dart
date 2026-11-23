import 'dart:async';
import 'dart:io';

import 'model_install_models.dart';
import 'model_install_port.dart';

/// Lets the caller stop an installation (the Models screen's cancel).
class ModelInstallCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _onCancel(void Function() listener) => _listeners.add(listener);
}

class ModelInstallCancelled implements Exception {
  const ModelInstallCancelled();
}

/// Downloads one artifact to [destination], reporting the bytes on disk.
/// It never verifies content: the converter checks size and SHA-256 when the
/// file is accepted.
typedef ArtifactDownloader =
    Future<void> Function({
      required Uri url,
      required String destination,
      required int expectedBytes,
      required void Function(int bytes) onBytes,
      required ModelInstallCancellation cancellation,
    });

/// Free bytes on the volume that holds [path].
typedef FreeBytes = Future<int> Function(String path);

/// Drives `converter_tts_model_install_operation_*` and yields its events.
///
/// The protocol (mirroring the Apple client): begin or recover the operation,
/// read the plan, download each artifact that is not accepted yet into its
/// `inbox_path` while recording progress, accept it, and publish once every
/// artifact is accepted. A failed preflight, download or verification is
/// reported through `fail` so the converter owns the terminal state.
class ModelInstallRunner {
  ModelInstallRunner({
    required this.operations,
    ArtifactDownloader? download,
    FreeBytes? freeBytes,
    this.progressStep = 64 * 1024,
  }) : _download = download ?? downloadArtifact,
       _freeBytes = freeBytes ?? freeDiskBytes;

  final ModelInstallOperations operations;
  final ArtifactDownloader _download;
  final FreeBytes _freeBytes;

  /// Progress is recorded at most once per this many bytes.
  final int progressStep;

  /// Installs [modelId] under [root]. The stream always ends with a terminal
  /// event (completed, cancelled or failed) unless the binding itself breaks,
  /// which surfaces as a stream error.
  Stream<ModelInstallEvent> install({
    required String modelId,
    required String root,
    ModelInstallCancellation? cancellation,
  }) {
    final controller = StreamController<ModelInstallEvent>();
    final token = cancellation ?? ModelInstallCancellation();
    unawaited(_run(controller, modelId, root, token));
    return controller.stream;
  }

  Future<void> _run(
    StreamController<ModelInstallEvent> out,
    String modelId,
    String root,
    ModelInstallCancellation token,
  ) async {
    ModelInstallOperation? operation;
    try {
      final available = await _freeBytes(root);
      operation =
          operations.recover(
            modelId: modelId,
            root: root,
            availableBytes: available,
          ) ??
          operations.begin(
            modelId: modelId,
            root: root,
            availableBytes: available,
          );
      final live = operation;
      token._onCancel(live.cancel);
      var plan = live.plan();
      out.add(plan.event);
      if (!plan.ready) return; // The plan's event already carries the failure.

      while (true) {
        if (token.isCancelled) throw const ModelInstallCancelled();
        final next = plan.artifacts.where((a) => !a.accepted).firstOrNull;
        if (next == null) break;
        await _fetch(live, next, token, out);
        try {
          live.accept(next.index, next.inboxPath);
        } on Object catch (error) {
          live.fail('verification_failed', error.toString());
          out.add(live.event());
          return;
        }
        plan = live.plan();
        out.add(live.event());
      }
      live.publish();
      out.add(live.event());
    } on ModelInstallCancelled {
      operation?.cancel();
      if (operation != null) out.add(operation.event());
    } on Object catch (error, stack) {
      final failed = operation;
      if (failed == null) {
        out.addError(error, stack);
      } else {
        try {
          failed.fail('download_failed', error.toString());
          out.add(failed.event());
        } on Object {
          out.addError(error, stack);
        }
      }
    } finally {
      operation?.dispose();
      await out.close();
    }
  }

  Future<void> _fetch(
    ModelInstallOperation operation,
    ModelInstallArtifact artifact,
    ModelInstallCancellation token,
    StreamController<ModelInstallEvent> out,
  ) async {
    var recorded = 0;
    await _download(
      url: Uri.parse(artifact.url),
      destination: artifact.inboxPath,
      expectedBytes: artifact.expectedBytes,
      cancellation: token,
      onBytes: (bytes) {
        if (bytes - recorded < progressStep && bytes < artifact.expectedBytes) {
          return;
        }
        recorded = bytes;
        operation.recordProgress(artifact.index, bytes);
        out.add(operation.event());
      },
    );
    if (token.isCancelled) throw const ModelInstallCancelled();
    operation.recordProgress(artifact.index, recorded);
  }
}

/// Default downloader over `dart:io`, following redirects and streaming to disk.
Future<void> downloadArtifact({
  required Uri url,
  required String destination,
  required int expectedBytes,
  required void Function(int bytes) onBytes,
  required ModelInstallCancellation cancellation,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  IOSink? sink;
  try {
    final request = await client.getUrl(url);
    request.followRedirects = true;
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final file = File(destination);
    await file.parent.create(recursive: true);
    if (await file.exists()) await file.delete();
    sink = file.openWrite();
    var bytes = 0;
    await for (final chunk in response) {
      if (cancellation.isCancelled) throw const ModelInstallCancelled();
      sink.add(chunk);
      bytes += chunk.length;
      onBytes(bytes);
    }
    await sink.flush();
  } finally {
    await sink?.close();
    client.close(force: true);
  }
}

/// Free space on the volume of [path]; the largest value when it cannot be
/// read, so an unreadable volume never blocks an installation by itself.
Future<int> freeDiskBytes(String path) async {
  const unknown = 0x7fffffffffffffff;
  try {
    await Directory(path).create(recursive: true);
    if (Platform.isWindows) {
      final drive = Directory(path).absolute.path.substring(0, 1);
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "(Get-PSDrive -Name '$drive').Free",
      ]);
      return int.tryParse((result.stdout as String).trim()) ?? unknown;
    }
    final result = await Process.run('df', ['-Pk', path]);
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return unknown;
    final columns = lines.last.trim().split(RegExp(r'\s+'));
    final kilobytes = int.tryParse(columns.length > 3 ? columns[3] : '');
    return kilobytes == null ? unknown : kilobytes * 1024;
  } on Object {
    return unknown;
  }
}
