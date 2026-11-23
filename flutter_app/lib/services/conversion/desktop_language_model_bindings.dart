import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'desktop_tts_model_adapter.dart';

typedef _LanguagesNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Uint32);
typedef _LanguagesDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, int);
typedef _StringArgNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _StringArgDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _ErrorNative = ffi.Pointer<Utf8> Function();
typedef _ErrorDart = ffi.Pointer<Utf8> Function();

/// Desktop binding of the language exports of converter-ffi
/// (`docs/models-by-language-contract.md`). Rust owns every decision here.
final class DesktopLanguageModelBindings {
  DesktopLanguageModelBindings({ffi.DynamicLibrary? library})
    : _library = library ?? DesktopTtsModelAdapter.openLibrary() {
    _languages = _library.lookupFunction<_LanguagesNative, _LanguagesDart>(
      'converter_tts_catalog_languages_json_v1',
    );
    _resolve = _library.lookupFunction<_StringArgNative, _StringArgDart>(
      'converter_tts_resolve_language_model_json_v1',
    );
    _book = _library.lookupFunction<_StringArgNative, _StringArgDart>(
      'converter_book_language_json_v1',
    );
    _free = _library.lookupFunction<_FreeNative, _FreeDart>('converter_string_free');
    _lastError = _library.lookupFunction<_ErrorNative, _ErrorDart>('converter_last_error');
  }

  final ffi.DynamicLibrary _library;
  late final _LanguagesDart _languages;
  late final _StringArgDart _resolve;
  late final _StringArgDart _book;
  late final _FreeDart _free;
  late final _ErrorDart _lastError;

  /// Pure and fast: safe on the UI isolate.
  String catalogLanguagesJson({required String platform, int androidApi = 0}) =>
      using((arena) => _read(_languages(platform.toNativeUtf8(allocator: arena), androidApi)));

  /// Pure and fast: safe on the UI isolate. Never downloads.
  String resolveJson(String requestJson) =>
      using((arena) => _read(_resolve(requestJson.toNativeUtf8(allocator: arena))));

  /// Blocking (parses the book): call it through [bookLanguageJsonInIsolate].
  String bookLanguageJson(String path) =>
      using((arena) => _read(_book(path.toNativeUtf8(allocator: arena))));

  String _read(ffi.Pointer<Utf8> pointer) {
    if (pointer == ffi.nullptr) {
      final error = _lastError();
      if (error == ffi.nullptr) {
        throw const DesktopTtsModelAdapterError('converter-ffi failed without an error');
      }
      final message = error.toDartString();
      _free(error);
      throw DesktopTtsModelAdapterError(message);
    }
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }
}

/// Runs the blocking book analysis off the UI isolate.
Future<String> bookLanguageJsonInIsolate(String libraryPath, String path) =>
    Isolate.run(
      () => DesktopLanguageModelBindings(
        library: ffi.DynamicLibrary.open(libraryPath),
      ).bookLanguageJson(path),
    );
