import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_app/services/conversion/model_install/android_model_install_operations.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_models.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plays the Kotlin side of `modelInstallOperation`.
class _FakeNative {
  final calls = <String>[];
  final accepted = <int>{};
  int stageIndex = 0;
  int downloaded = 0;
  String? recoverResult;
  String? failOn;

  /// What the native recover/create return: -1 is "nothing to resume". A real handle is a
  /// pointer, which is negative as a signed Long on devices with tagged heap pointers.
  int recoverHandle = -1;
  int createHandle = 42;
  int? liveHandle;

  Object? handle(MethodCall call) {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final op = args['op'] as String;
    calls.add(op);
    if (failOn == op) {
      throw PlatformException(
        code: 'EMBEDDED_CONVERTER_UNAVAILABLE',
        message: 'native $op failed',
      );
    }
    switch (op) {
      case 'freeBytes':
        return 10 * 1024 * 1024 * 1024;
      case 'recover':
        if (recoverHandle != -1) liveHandle = recoverHandle;
        return recoverHandle;
      case 'create':
        expect(args['availableBytes'], 10 * 1024 * 1024 * 1024);
        liveHandle = createHandle;
        return createHandle;
      case 'plan':
        expect(args['handle'], liveHandle);
        return jsonEncode({
          'operation_id': 'op',
          'model_id': 'm',
          'required_bytes': 200,
          'available_bytes': 10 << 30,
          'ready': true,
          'artifacts': [
            for (var i = 0; i < 2; i++)
              {
                'index': i,
                'name': 'f$i',
                'url': 'https://example.test/f$i',
                'sha256': 'x',
                'expected_bytes': 100,
                'inbox_path': '/inbox/f$i',
                'accepted': accepted.contains(i),
              },
          ],
          'event': _event('preflight'),
        });
      case 'event':
        return jsonEncode(
          _event(accepted.length == 2 ? 'completed' : 'downloading'),
        );
      case 'recordProgress':
        downloaded = args['bytes'] as int;
        return null;
      case 'accept':
        accepted.add(args['index'] as int);
        return null;
      case 'publish':
        return '/models/m';
      default:
        return null;
    }
  }

  Map<String, Object?> _event(String stage) => {
    'sequence': calls.length,
    'operation_id': 'op',
    'model_id': 'm',
    'stage': stage,
    'bytes_completed': downloaded,
    'bytes_total': 200,
  };
}

Future<void> _fakeDownload({
  required Uri url,
  required String destination,
  required int expectedBytes,
  required void Function(int) onBytes,
  required ModelInstallCancellation cancellation,
}) async {
  for (var bytes = 50; bytes <= expectedBytes; bytes += 50) {
    onBytes(bytes);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('android_model_install_test');
  late _FakeNative native;

  setUp(() {
    native = _FakeNative();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'modelInstallOperation');
          return native.handle(call);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  test('a full install runs the operation through the channel and frees the handle', () async {
    final operations = AndroidModelInstallOperations(channel);
    final events = await ModelInstallRunner(
      operations: operations,
      download: _fakeDownload,
      freeBytes: operations.freeBytes,
      progressStep: 50,
    ).install(modelId: 'm', root: '/models').toList();

    expect(events.last.stage, ModelInstallStage.completed);
    expect(native.calls.first, 'freeBytes');
    expect(native.calls.sublist(1, 3), [
      'recover',
      'create',
    ], reason: 'recover first, then begin');
    expect(native.calls.where((c) => c == 'accept').length, 2);
    expect(native.calls.where((c) => c == 'recordProgress'), isNotEmpty);
    expect(native.calls, containsAllInOrder(['publish', 'free']));
    expect(native.calls.last, 'free');
  });

  test(
    'a native failure while accepting fails the operation and still frees it',
    () async {
      native.failOn = 'accept';
      final operations = AndroidModelInstallOperations(channel);
      final events = await ModelInstallRunner(
        operations: operations,
        download: _fakeDownload,
        freeBytes: operations.freeBytes,
      ).install(modelId: 'm', root: '/models').toList();

      expect(native.calls, containsAllInOrder(['accept', 'fail', 'free']));
      expect(native.calls, isNot(contains('publish')));
      expect(events.last.stage, isNot(ModelInstallStage.completed));
    },
  );

  test('cancelling reaches the native operation', () async {
    final operations = AndroidModelInstallOperations(channel);
    final token = ModelInstallCancellation();
    final events = <ModelInstallEvent>[];
    await for (final event in ModelInstallRunner(
      operations: operations,
      download:
          ({
            required url,
            required destination,
            required expectedBytes,
            required onBytes,
            required cancellation,
          }) async {
            token.cancel();
            await Future<void>.delayed(const Duration(milliseconds: 5));
            if (cancellation.isCancelled) throw const ModelInstallCancelled();
          },
      freeBytes: operations.freeBytes,
    ).install(modelId: 'm', root: '/models', cancellation: token)) {
      events.add(event);
    }
    expect(native.calls, contains('cancel'));
    expect(native.calls, isNot(contains('publish')));
    expect(native.calls.last, 'free');
  });

  // SM-X620 (Android 14): the native handle is a pointer with a heap tag in the top byte,
  // so it is negative as a Long. Only 0 is an error and only -1 means "nothing to resume".
  const tagged = -5476376642457427968; // 0xB4000000_00000000

  test('a native handle that is negative as a Long (tagged pointer) is a live operation', () async {
    native.createHandle = tagged;
    final operations = AndroidModelInstallOperations(channel);
    final events = await ModelInstallRunner(
      operations: operations,
      download: _fakeDownload,
      freeBytes: operations.freeBytes,
      progressStep: 50,
    ).install(modelId: 'm', root: '/models').toList();

    expect(events.last.stage, ModelInstallStage.completed);
    expect(native.calls.where((c) => c == 'create').length, 1);
    expect(native.calls, containsAllInOrder(['publish', 'free']));
  });

  test('an interrupted operation recovered with a tagged handle is resumed, never created twice', () async {
    native.recoverHandle = tagged;
    final operations = AndroidModelInstallOperations(channel);
    final events = await ModelInstallRunner(
      operations: operations,
      download: _fakeDownload,
      freeBytes: operations.freeBytes,
      progressStep: 50,
    ).install(modelId: 'm', root: '/models').toList();

    expect(events.last.stage, ModelInstallStage.completed);
    expect(
      native.calls,
      isNot(contains('create')),
      reason: 'the recovered operation is used as is',
    );
    expect(
      native.calls,
      containsAllInOrder(['recover', 'plan', 'publish', 'free']),
    );
  });
}
