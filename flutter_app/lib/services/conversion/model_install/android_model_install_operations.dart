import 'dart:convert';

import 'package:flutter/services.dart';

import 'model_install_models.dart';
import 'model_install_port.dart';

/// Reaches `converter_tts_model_install_operation_*` through the Android
/// `modelInstallOperation` method channel (JNI on the native side). The handle
/// is an opaque `long` owned by this object until [dispose].
class AndroidModelInstallOperations implements ModelInstallOperations {
  AndroidModelInstallOperations(this._channel);

  final MethodChannel _channel;

  Future<T?> _invoke<T>(String op, Map<String, Object?> arguments) =>
      _channel.invokeMethod<T>('modelInstallOperation', {
        'op': op,
        ...arguments,
      });

  /// Free bytes on the volume of [root], from the platform file system.
  Future<int> freeBytes(String root) async =>
      (await _invoke<int>('freeBytes', {'root': root})) ?? 0;

  @override
  Future<ModelInstallOperation> begin({
    required String modelId,
    required String root,
    required int availableBytes,
  }) async {
    final handle = await _create('create', modelId, root, availableBytes);
    if (handle == null) {
      throw StateError('The converter did not start an installation');
    }
    return handle;
  }

  @override
  Future<ModelInstallOperation?> recover({
    required String modelId,
    required String root,
    required int availableBytes,
  }) => _create('recover', modelId, root, availableBytes);

  Future<ModelInstallOperation?> _create(
    String op,
    String modelId,
    String root,
    int availableBytes,
  ) async {
    final handle = await _invoke<int>(op, {
      'modelId': modelId,
      'root': root,
      'availableBytes': availableBytes,
    });
    // Zero is an error (thrown by the channel); -1 is "nothing to recover". Any other
    // value is a native pointer: with tagged heap pointers (Android 11+ on some devices,
    // e.g. the SM-X620) it is negative as a signed Long, so the sign says nothing.
    if (handle == null || handle == 0 || handle == -1) return null;
    return _AndroidOperation(this, handle);
  }
}

final class _AndroidOperation implements ModelInstallOperation {
  _AndroidOperation(this._owner, this._handle);

  final AndroidModelInstallOperations _owner;
  final int _handle;
  bool _disposed = false;

  Future<T?> _call<T>(String op, [Map<String, Object?> arguments = const {}]) =>
      _owner._invoke<T>(op, {'handle': _handle, ...arguments});

  Future<Map<String, dynamic>> _json(String op) async {
    final raw = await _call<String>(op);
    if (raw == null || raw.isEmpty) {
      throw StateError('Empty install operation $op');
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<ModelInstallPlan> plan() async =>
      ModelInstallPlan.fromJson(await _json('plan'));

  @override
  Future<ModelInstallEvent> event() async =>
      ModelInstallEvent.fromJson(await _json('event'));

  @override
  Future<void> recordProgress(int index, int downloadedBytes) =>
      _call<void>('recordProgress', {'index': index, 'bytes': downloadedBytes});

  @override
  Future<void> accept(int index, String downloadedPath) =>
      _call<void>('accept', {'index': index, 'path': downloadedPath});

  @override
  Future<String> publish() async => (await _call<String>('publish')) ?? '';

  @override
  Future<void> fail(String kind, String message) =>
      _call<void>('fail', {'kind': kind, 'message': message});

  @override
  Future<void> cancel() => _call<void>('cancel');

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _call<void>('free');
  }
}
