import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../desktop_tts_model_adapter.dart';
import 'model_install_models.dart';
import 'model_install_port.dart';

typedef _CreateNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Uint64,
    );
typedef _CreateDart =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
    );
typedef _JsonNative = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _JsonDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _ProgressNative =
    ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.IntPtr, ffi.Uint64);
typedef _ProgressDart = bool Function(ffi.Pointer<ffi.Void>, int, int);
typedef _AcceptNative =
    ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.IntPtr, ffi.Pointer<Utf8>);
typedef _AcceptDart = bool Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<Utf8>);
typedef _FailNative =
    ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _FailDart =
    bool Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _VoidHandleNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _VoidHandleDart = void Function(ffi.Pointer<ffi.Void>);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _ErrorNative = ffi.Pointer<Utf8> Function();
typedef _ErrorDart = ffi.Pointer<Utf8> Function();

/// Desktop binding of `converter_tts_model_install_operation_*` over the
/// shared converter-ffi library. It carries no model URLs, checksums or
/// storage rules: the operation plan supplies them.
final class DesktopModelInstallOperations implements ModelInstallOperations {
  DesktopModelInstallOperations({ffi.DynamicLibrary? library})
    : _library = library ?? DesktopTtsModelAdapter.openLibrary() {
    _create = _library.lookupFunction<_CreateNative, _CreateDart>(
      'converter_tts_model_install_operation_create',
    );
    _recover = _library.lookupFunction<_CreateNative, _CreateDart>(
      'converter_tts_model_install_operation_recover',
    );
    _plan = _library.lookupFunction<_JsonNative, _JsonDart>(
      'converter_tts_model_install_operation_plan_json',
    );
    _event = _library.lookupFunction<_JsonNative, _JsonDart>(
      'converter_tts_model_install_operation_event_json',
    );
    _record = _library.lookupFunction<_ProgressNative, _ProgressDart>(
      'converter_tts_model_install_operation_record_progress',
    );
    _accept = _library.lookupFunction<_AcceptNative, _AcceptDart>(
      'converter_tts_model_install_operation_accept_download',
    );
    _publish = _library.lookupFunction<_JsonNative, _JsonDart>(
      'converter_tts_model_install_operation_publish',
    );
    _fail = _library.lookupFunction<_FailNative, _FailDart>(
      'converter_tts_model_install_operation_fail',
    );
    _cancel = _library.lookupFunction<_VoidHandleNative, _VoidHandleDart>(
      'converter_tts_model_install_operation_cancel',
    );
    _release = _library.lookupFunction<_VoidHandleNative, _VoidHandleDart>(
      'converter_tts_model_install_operation_free',
    );
    _free = _library.lookupFunction<_FreeNative, _FreeDart>(
      'converter_string_free',
    );
    _lastError = _library.lookupFunction<_ErrorNative, _ErrorDart>(
      'converter_last_error',
    );
  }

  final ffi.DynamicLibrary _library;
  late final _CreateDart _create;
  late final _CreateDart _recover;
  late final _JsonDart _plan;
  late final _JsonDart _event;
  late final _ProgressDart _record;
  late final _AcceptDart _accept;
  late final _JsonDart _publish;
  late final _FailDart _fail;
  late final _VoidHandleDart _cancel;
  late final _VoidHandleDart _release;
  late final _FreeDart _free;
  late final _ErrorDart _lastError;

  @override
  ModelInstallOperation begin({
    required String modelId,
    required String root,
    required int availableBytes,
  }) {
    final handle = _open(_create, modelId, root, availableBytes);
    if (handle == ffi.nullptr) throw ModelInstallBindingError(_error());
    return _DesktopOperation(this, handle);
  }

  @override
  ModelInstallOperation? recover({
    required String modelId,
    required String root,
    required int availableBytes,
  }) {
    final handle = _open(_recover, modelId, root, availableBytes);
    if (handle != ffi.nullptr) return _DesktopOperation(this, handle);
    // A null handle with no error means there was nothing to recover.
    final message = _error(consume: true);
    if (message.isEmpty) return null;
    throw ModelInstallBindingError(message);
  }

  ffi.Pointer<ffi.Void> _open(
    _CreateDart open,
    String modelId,
    String root,
    int availableBytes,
  ) => using(
    (arena) => open(
      modelId.toNativeUtf8(allocator: arena),
      root.toNativeUtf8(allocator: arena),
      availableBytes,
    ),
  );

  String _error({bool consume = false}) {
    final pointer = _lastError();
    if (pointer == ffi.nullptr) {
      return consume ? '' : 'unknown model installation error';
    }
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }

  String _json(_JsonDart read, ffi.Pointer<ffi.Void> handle) {
    final pointer = read(handle);
    if (pointer == ffi.nullptr) throw ModelInstallBindingError(_error());
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }
}

/// A failure of the converter binding itself (not a failed installation).
class ModelInstallBindingError implements Exception {
  const ModelInstallBindingError(this.message);
  final String message;

  @override
  String toString() => 'ModelInstallBindingError: $message';
}

final class _DesktopOperation implements ModelInstallOperation {
  _DesktopOperation(this._owner, this._handle);

  final DesktopModelInstallOperations _owner;
  final ffi.Pointer<ffi.Void> _handle;
  bool _disposed = false;

  @override
  ModelInstallPlan plan() => ModelInstallPlan.fromJson(
    jsonDecode(_owner._json(_owner._plan, _handle)) as Map<String, dynamic>,
  );

  @override
  ModelInstallEvent event() => ModelInstallEvent.fromJson(
    jsonDecode(_owner._json(_owner._event, _handle)) as Map<String, dynamic>,
  );

  @override
  void recordProgress(int index, int downloadedBytes) {
    if (!_owner._record(_handle, index, downloadedBytes)) {
      throw ModelInstallBindingError(_owner._error());
    }
  }

  @override
  void accept(int index, String downloadedPath) {
    final accepted = using(
      (arena) => _owner._accept(
        _handle,
        index,
        downloadedPath.toNativeUtf8(allocator: arena),
      ),
    );
    if (!accepted) throw ModelInstallBindingError(_owner._error());
  }

  @override
  String publish() => _owner._json(_owner._publish, _handle);

  @override
  void fail(String kind, String message) {
    final recorded = using(
      (arena) => _owner._fail(
        _handle,
        kind.toNativeUtf8(allocator: arena),
        message.toNativeUtf8(allocator: arena),
      ),
    );
    if (!recorded) throw ModelInstallBindingError(_owner._error());
  }

  @override
  void cancel() {
    if (!_disposed) _owner._cancel(_handle);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner._release(_handle);
  }
}
