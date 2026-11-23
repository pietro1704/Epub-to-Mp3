import 'dart:async';
import 'dart:io';

import 'package:flutter_app/services/conversion/model_install/model_install_models.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_port.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scriptable stand-in for the converter's install operation.
class _FakeOperation implements ModelInstallOperation {
  _FakeOperation(this.artifacts, {this.ready = true, this.acceptError});

  final List<ModelInstallArtifact> artifacts;
  final bool ready;
  final Object? acceptError;
  final log = <String>[];
  final accepted = <int>{};
  ModelInstallStage stage = ModelInstallStage.preflight;
  int completed = 0;
  ModelInstallFailure? failure;
  bool disposed = false;
  int sequence = 0;

  int get total => artifacts.fold(0, (sum, a) => sum + a.expectedBytes);

  ModelInstallEvent _event() => ModelInstallEvent(
    sequence: ++sequence,
    modelId: 'm',
    stage: stage,
    bytesCompleted: completed,
    bytesTotal: total,
    failure: failure,
  );

  @override
  ModelInstallPlan plan() => ModelInstallPlan(
    operationId: 'op',
    modelId: 'm',
    requiredBytes: total,
    availableBytes: ready ? 1 << 40 : 1,
    ready: ready,
    event: ready
        ? _event()
        : ModelInstallEvent(
            sequence: 0,
            modelId: 'm',
            stage: ModelInstallStage.failed,
            bytesCompleted: 0,
            bytesTotal: total,
            failure: const ModelInstallFailure(kind: 'insufficient_space', message: 'no room'),
          ),
    artifacts: [
      for (final a in artifacts)
        ModelInstallArtifact(
          index: a.index,
          name: a.name,
          url: a.url,
          sha256: a.sha256,
          expectedBytes: a.expectedBytes,
          inboxPath: a.inboxPath,
          accepted: accepted.contains(a.index),
        ),
    ],
  );

  @override
  ModelInstallEvent event() => _event();

  @override
  void recordProgress(int index, int downloadedBytes) {
    log.add('progress:$index:$downloadedBytes');
    stage = ModelInstallStage.downloading;
    completed = downloadedBytes;
  }

  @override
  void accept(int index, String downloadedPath) {
    log.add('accept:$index:$downloadedPath');
    if (acceptError != null) throw acceptError!;
    accepted.add(index);
    stage = ModelInstallStage.verifying;
  }

  @override
  String publish() {
    log.add('publish');
    stage = ModelInstallStage.completed;
    return '/models/m';
  }

  @override
  void fail(String kind, String message) {
    log.add('fail:$kind');
    stage = ModelInstallStage.failed;
    failure = ModelInstallFailure(kind: kind, message: message);
  }

  @override
  void cancel() {
    log.add('cancel');
    stage = ModelInstallStage.cancelled;
  }

  @override
  void dispose() => disposed = true;
}

class _FakeOperations implements ModelInstallOperations {
  _FakeOperations(this.operation, {this.recovered = false});
  final _FakeOperation operation;
  final bool recovered;
  final calls = <String>[];

  @override
  ModelInstallOperation begin({required String modelId, required String root, required int availableBytes}) {
    calls.add('begin:$availableBytes');
    return operation;
  }

  @override
  ModelInstallOperation? recover({required String modelId, required String root, required int availableBytes}) {
    calls.add('recover');
    return recovered ? operation : null;
  }
}

ModelInstallArtifact _artifact(int index, int bytes) => ModelInstallArtifact(
  index: index,
  name: 'file$index',
  url: 'https://example.test/file$index',
  sha256: 'abc',
  expectedBytes: bytes,
  inboxPath: '/inbox/file$index',
  accepted: false,
);

ArtifactDownloader _downloader(List<String> log, {int chunk = 100, Object? failWith}) =>
    ({required url, required destination, required expectedBytes, required onBytes, required cancellation}) async {
      log.add('download:${url.path}->$destination');
      if (failWith != null) throw failWith;
      for (var bytes = chunk; ; bytes += chunk) {
        if (cancellation.isCancelled) throw const ModelInstallCancelled();
        final reported = bytes > expectedBytes ? expectedBytes : bytes;
        onBytes(reported);
        await Future<void>.delayed(Duration.zero);
        if (reported >= expectedBytes) return;
      }
    };

ModelInstallRunner _runner(_FakeOperations operations, ArtifactDownloader download, {int step = 100}) =>
    ModelInstallRunner(
      operations: operations,
      download: download,
      freeBytes: (_) async => 5000,
      progressStep: step,
    );

void main() {
  test('installs every artifact in order, reports progress and publishes', () async {
    final operation = _FakeOperation([_artifact(0, 250), _artifact(1, 100)]);
    final operations = _FakeOperations(operation);
    final downloads = <String>[];
    final events = await _runner(operations, _downloader(downloads)).install(modelId: 'm', root: '/root').toList();

    expect(operations.calls, ['recover', 'begin:5000'], reason: 'recovers first, free bytes reported');
    expect(downloads, ['download:/file0->/inbox/file0', 'download:/file1->/inbox/file1']);
    expect(operation.log.where((e) => e.startsWith('accept')), ['accept:0:/inbox/file0', 'accept:1:/inbox/file1']);
    expect(operation.log.last, 'publish');
    expect(events.last.stage, ModelInstallStage.completed);
    expect(operation.disposed, isTrue);
    final downloading = events.where((e) => e.stage == ModelInstallStage.downloading);
    expect(downloading, isNotEmpty);
    expect(downloading.last.fraction, isNotNull);
    // Progress is recorded in bytes of the artifact being downloaded.
    expect(operation.log.where((e) => e.startsWith('progress:0')).last, 'progress:0:250');
  });

  test('progress is throttled to the step instead of every chunk', () async {
    final operation = _FakeOperation([_artifact(0, 1000)]);
    final events = await _runner(
      _FakeOperations(operation),
      _downloader([], chunk: 10),
      step: 300,
    ).install(modelId: 'm', root: '/r').toList();
    final recorded = operation.log.where((e) => e.startsWith('progress:0')).length;
    expect(recorded, lessThan(10), reason: '100 chunks, one record per 300 bytes plus the final');
    expect(events.last.stage, ModelInstallStage.completed);
  });

  test('a refused preflight ends with the converter failure and downloads nothing', () async {
    final operation = _FakeOperation([_artifact(0, 250)], ready: false);
    final downloads = <String>[];
    final events = await _runner(_FakeOperations(operation), _downloader(downloads)).install(modelId: 'm', root: '/r').toList();
    expect(downloads, isEmpty);
    expect(events.single.stage, ModelInstallStage.failed);
    expect(events.single.failure?.kind, 'insufficient_space');
    expect(operation.disposed, isTrue);
  });

  test('a recovered installation skips artifacts the converter already accepted', () async {
    final operation = _FakeOperation([_artifact(0, 100), _artifact(1, 100)])..accepted.add(0);
    final operations = _FakeOperations(operation, recovered: true);
    final downloads = <String>[];
    final events = await _runner(operations, _downloader(downloads)).install(modelId: 'm', root: '/r').toList();
    expect(operations.calls, ['recover'], reason: 'no fresh begin when there is something to recover');
    expect(downloads, ['download:/file1->/inbox/file1']);
    expect(events.last.stage, ModelInstallStage.completed);
  });

  test('a network failure is reported through the converter as a failed install', () async {
    final operation = _FakeOperation([_artifact(0, 100)]);
    final events = await _runner(
      _FakeOperations(operation),
      _downloader([], failWith: const SocketException('offline')),
    ).install(modelId: 'm', root: '/r').toList();
    expect(operation.log, contains('fail:download_failed'));
    expect(events.last.stage, ModelInstallStage.failed);
    expect(events.last.failure?.message, contains('offline'));
    expect(operation.log, isNot(contains('publish')));
    expect(operation.disposed, isTrue);
  });

  test('a rejected download fails verification and is never published', () async {
    final operation = _FakeOperation([_artifact(0, 100)], acceptError: StateError('checksum mismatch'));
    final events = await _runner(_FakeOperations(operation), _downloader([])).install(modelId: 'm', root: '/r').toList();
    expect(operation.log, contains('fail:verification_failed'));
    expect(operation.log, isNot(contains('publish')));
    expect(events.last.stage, ModelInstallStage.failed);
  });

  test('cancelling stops the download, cancels the operation and reports it', () async {
    final operation = _FakeOperation([_artifact(0, 100000)]);
    final token = ModelInstallCancellation();
    final events = <ModelInstallEvent>[];
    final done = Completer<void>();
    _runner(_FakeOperations(operation), _downloader([], chunk: 100), step: 100)
        .install(modelId: 'm', root: '/r', cancellation: token)
        .listen((event) {
          events.add(event);
          if (event.bytesCompleted >= 500 && !token.isCancelled) token.cancel();
        }, onDone: done.complete);
    await done.future;
    expect(operation.log, contains('cancel'));
    expect(operation.log, isNot(contains('publish')));
    expect(events.last.stage, ModelInstallStage.cancelled);
    expect(events.last.bytesCompleted, lessThan(100000));
    expect(operation.disposed, isTrue);
  });

  test('a binding error before the operation exists surfaces as a stream error', () async {
    final runner = ModelInstallRunner(
      operations: _ThrowingOperations(),
      download: _downloader([]),
      freeBytes: (_) async => 1,
    );
    await expectLater(runner.install(modelId: 'm', root: '/r'), emitsError(isA<StateError>()));
  });

  test('plan and event JSON decode the converter shapes', () {
    final plan = ModelInstallPlan.fromJson({
      'operation_id': 'op1',
      'model_id': 'pt_BR-faber-medium',
      'revision': 'r1',
      'required_bytes': 61000000,
      'available_bytes': 9000000000,
      'ready': true,
      'artifacts': [
        {
          'index': 0,
          'name': 'model.onnx',
          'url': 'https://huggingface.co/x/model.onnx',
          'sha256': 'ab',
          'expected_bytes': 60000000,
          'inbox_path': '/models/.inbox/model.onnx',
          'accepted': false,
        },
      ],
      'event': {
        'sequence': 3,
        'operation_id': 'op1',
        'model_id': 'pt_BR-faber-medium',
        'stage': 'downloading',
        'artifact_index': 0,
        'bytes_completed': 30000000,
        'bytes_total': 60000000,
      },
    });
    expect(plan.ready, isTrue);
    expect(plan.artifacts.single.inboxPath, '/models/.inbox/model.onnx');
    expect(plan.event.stage, ModelInstallStage.downloading);
    expect(plan.event.fraction, 0.5);
    final failed = ModelInstallEvent.fromJson({
      'stage': 'failed',
      'bytes_total': 0,
      'failure': {'kind': 'insufficient_space', 'message': 'x', 'required_bytes': 5, 'available_bytes': 1},
    });
    expect(failed.stage.terminal, isTrue);
    expect(failed.fraction, isNull);
    expect(failed.failure?.requiredBytes, 5);
    expect(ModelInstallStage.parse('something-new'), ModelInstallStage.preflight);
  });
}

class _ThrowingOperations implements ModelInstallOperations {
  @override
  ModelInstallOperation begin({required String modelId, required String root, required int availableBytes}) =>
      throw StateError('binding down');

  @override
  ModelInstallOperation? recover({required String modelId, required String root, required int availableBytes}) => null;
}
