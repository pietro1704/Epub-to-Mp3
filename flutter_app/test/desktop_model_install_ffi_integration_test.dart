import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_app/services/conversion/model_install/desktop_model_install_operations.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_models.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs against the real converter-ffi library; set TTS_TEST_FFI_LIBRARY to it.
void main() {
  final libraryPath = Platform.environment['TTS_TEST_FFI_LIBRARY'];
  final skip = libraryPath == null || !File(libraryPath).existsSync()
      ? 'Set TTS_TEST_FFI_LIBRARY to a converter-ffi library'
      : null;
  const modelId = 'pt_BR-faber-medium';

  test('the converter plans a catalog install and Dart reads the plan', () async {
    final root = await Directory.systemTemp.createTemp('model-install-ffi-');
    addTearDown(() => root.delete(recursive: true));
    final operations = DesktopModelInstallOperations(
      library: ffi.DynamicLibrary.open(libraryPath!),
    );
    final operation = operations.begin(
      modelId: modelId,
      root: root.path,
      availableBytes: await freeDiskBytes(root.path),
    );
    addTearDown(operation.dispose);

    final plan = await operation.plan();
    expect(plan.modelId, modelId);
    expect(plan.ready, isTrue);
    expect(plan.requiredBytes, greaterThan(1000000));
    expect(plan.artifacts, isNotEmpty);
    for (final artifact in plan.artifacts) {
      expect(Uri.parse(artifact.url).scheme, 'https');
      expect(artifact.sha256, hasLength(64));
      expect(artifact.expectedBytes, greaterThan(0));
      expect(artifact.accepted, isFalse);
      expect(artifact.inboxPath, startsWith(root.path), reason: 'inbox lives under the model root');
    }
    expect(plan.event.stage, isIn([ModelInstallStage.preflight, ModelInstallStage.downloading]));
    expect(
      plan.event.bytesTotal,
      plan.artifacts.fold<int>(0, (sum, artifact) => sum + artifact.expectedBytes),
      reason: 'the event totals the downloads; required bytes add install headroom',
    );

    // The same model cannot be installed twice at once.
    expect(
      () async => operations.begin(modelId: modelId, root: root.path, availableBytes: 1 << 40),
      throwsA(isA<ModelInstallBindingError>().having((e) => e.message, 'message', contains('duplicate'))),
    );

    await operation.recordProgress(0, 1234);
    expect((await operation.event()).bytesCompleted, 1234);
    expect((await operation.event()).stage, ModelInstallStage.downloading);

    await operation.cancel();
    expect((await operation.event()).stage, ModelInstallStage.cancelled);
  }, skip: skip);

  test('a preflight with too little space is refused by the converter', () async {
    final root = await Directory.systemTemp.createTemp('model-install-ffi-');
    addTearDown(() => root.delete(recursive: true));
    final operations = DesktopModelInstallOperations(
      library: ffi.DynamicLibrary.open(libraryPath!),
    );
    final operation = operations.begin(modelId: modelId, root: root.path, availableBytes: 1024);
    addTearDown(operation.dispose);
    final plan = await operation.plan();
    expect(plan.ready, isFalse);
    expect(plan.event.stage, ModelInstallStage.failed);
    expect(plan.event.failure?.kind, isNotEmpty);
    expect(plan.event.failure?.requiredBytes, greaterThan(1024));
  }, skip: skip);

  test('recover finds nothing to recover for a model that was never started', () async {
    final root = await Directory.systemTemp.createTemp('model-install-ffi-');
    addTearDown(() => root.delete(recursive: true));
    final operations = DesktopModelInstallOperations(
      library: ffi.DynamicLibrary.open(libraryPath!),
    );
    expect(operations.recover(modelId: modelId, root: root.path, availableBytes: 1 << 40), isNull);
  }, skip: skip);

  test('a real install downloads, verifies and publishes the model with progress', () async {
    // flutter_test blocks real HTTP by default.
    HttpOverrides.global = null;
    final root = await Directory.systemTemp.createTemp('model-install-net-');
    addTearDown(() => root.delete(recursive: true));
    final runner = ModelInstallRunner(
      operations: DesktopModelInstallOperations(library: ffi.DynamicLibrary.open(libraryPath!)),
    );
    final events = await runner.install(modelId: modelId, root: root.path).toList();

    expect(events.last.stage, ModelInstallStage.completed, reason: '${events.last.failure?.message}');
    final downloading = events.where((e) => e.stage == ModelInstallStage.downloading).toList();
    expect(downloading.length, greaterThan(3), reason: 'progress is reported while downloading');
    final fractions = downloading.map((e) => e.bytesCompleted).toList();
    expect(fractions.last, greaterThan(fractions.first));
    expect(events.every((e) => (e.fraction ?? 0) <= 1.0), isTrue);
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains(modelId))
        .toList();
    expect(files.any((f) => f.path.endsWith('.onnx')), isTrue, reason: 'published model files: $files');
    expect(files.any((f) => f.path.contains('.inbox')), isFalse, reason: 'the inbox is cleaned up');
  }, skip: skip ?? (Platform.environment['TTS_TEST_NETWORK_INSTALL'] == '1' ? null : 'Set TTS_TEST_NETWORK_INSTALL=1 to download a real model'),
      timeout: const Timeout(Duration(minutes: 10)));
}
