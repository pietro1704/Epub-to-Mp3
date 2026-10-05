import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

class DesktopTtsModelAdapterError implements Exception {
  const DesktopTtsModelAdapterError(this.message);

  final String message;

  @override
  String toString() => 'DesktopTtsModelAdapterError: $message';
}

typedef _ModelsNative = ffi.Pointer<Utf8> Function();
typedef _ModelsDart = ffi.Pointer<Utf8> Function();
typedef _InstallNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _InstallDart =
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _RemoveNative = ffi.Bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _RemoveDart = bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _MetadataNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _MetadataDart =
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _InstalledReadyEngineNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Uint32,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
    );
typedef _InstalledReadyEngineDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
    );
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _ErrorNative = ffi.Pointer<Utf8> Function();
typedef _ErrorDart = ffi.Pointer<Utf8> Function();
typedef _JobLogNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _JobLogDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

/// Thin desktop adapter over the shared converter-ffi catalog and ModelStore.
/// It never contains model URLs, checksums, or selection policy.
final class DesktopTtsModelAdapter {
  DesktopTtsModelAdapter({ffi.DynamicLibrary? library})
    : _library = library ?? _openLibrary() {
    _models = _library.lookupFunction<_ModelsNative, _ModelsDart>(
      'converter_tts_models_json',
    );
    _install = _library.lookupFunction<_InstallNative, _InstallDart>(
      'converter_tts_model_install_catalog_manifest',
    );
    _remove = _library.lookupFunction<_RemoveNative, _RemoveDart>(
      'converter_tts_model_remove',
    );
    _metadata = _library.lookupFunction<_MetadataNative, _MetadataDart>(
      'converter_tts_model_metadata',
    );
    _installedReadyEngine = _library
        .lookupFunction<_InstalledReadyEngineNative, _InstalledReadyEngineDart>(
          'converter_tts_installed_ready_engine',
        );
    _free = _library.lookupFunction<_FreeNative, _FreeDart>(
      'converter_string_free',
    );
    _lastError = _library.lookupFunction<_ErrorNative, _ErrorDart>(
      'converter_last_error',
    );
    _jobLog = _library.lookupFunction<_JobLogNative, _JobLogDart>(
      'converter_job_log_json',
    );
  }

  final ffi.DynamicLibrary _library;
  late final _ModelsDart _models;
  late final _InstallDart _install;
  late final _RemoveDart _remove;
  late final _MetadataDart _metadata;
  late final _InstalledReadyEngineDart _installedReadyEngine;
  late final _FreeDart _free;
  late final _ErrorDart _lastError;
  late final _JobLogDart _jobLog;

  String jobLog({required String jobId}) => using((arena) {
        final result = _jobLog(jobId.toNativeUtf8(allocator: arena));
        return _readOwned(result);
      });

  String modelsJson() => _readOwned(_models());

  String installedReadyEngine({
    required String language,
    required String platform,
    required String installedModelIdsJson,
    required String readyModelIdsJson,
    int androidApi = 0,
  }) {
    return using((arena) {
      final result = _installedReadyEngine(
        language.toNativeUtf8(allocator: arena),
        platform.toNativeUtf8(allocator: arena),
        androidApi,
        installedModelIdsJson.toNativeUtf8(allocator: arena),
        readyModelIdsJson.toNativeUtf8(allocator: arena),
      );
      return _readOwned(result);
    });
  }

  String installFromCatalog({required String modelId, required String root}) {
    return using((arena) {
      final result = _install(
        modelId.toNativeUtf8(allocator: arena),
        root.toNativeUtf8(allocator: arena),
      );
      if (result == ffi.nullptr) {
        throw DesktopTtsModelAdapterError(_readError());
      }
      return _readOwned(result);
    });
  }

  bool remove({required String modelId, required String root}) {
    return using((arena) {
      final removed = _remove(
        modelId.toNativeUtf8(allocator: arena),
        root.toNativeUtf8(allocator: arena),
      );
      if (!removed) throw DesktopTtsModelAdapterError(_readError());
      return true;
    });
  }

  String? metadata({required String modelId, required String root}) {
    return using((arena) {
      final result = _metadata(
        modelId.toNativeUtf8(allocator: arena),
        root.toNativeUtf8(allocator: arena),
      );
      if (result == ffi.nullptr) return null;
      return _readOwned(result);
    });
  }

  String _readOwned(ffi.Pointer<Utf8> pointer) {
    if (pointer == ffi.nullptr) throw DesktopTtsModelAdapterError(_readError());
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }

  String _readError() {
    final pointer = _lastError();
    if (pointer == ffi.nullptr) return 'unknown converter-ffi error';
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }

  static ffi.DynamicLibrary _openLibrary() {
    final override = Platform.environment['EPUBTOMP3_CONVERTER_FFI'];
    if (override != null && override.isNotEmpty) {
      return ffi.DynamicLibrary.open(override);
    }
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('converter_ffi.dll');
    }
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('libconverter_ffi.dylib');
    }
    return ffi.DynamicLibrary.open('libconverter_ffi.so');
  }
}
