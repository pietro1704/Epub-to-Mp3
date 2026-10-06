import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';

final class _NativeSession extends ffi.Opaque {}

typedef _OpenNative = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _OpenDart = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _MetadataNative = ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _MetadataDart = ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _ConvertNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<_NativeSession>,
  ffi.Pointer<Utf8>,
  ffi.Int32,
  ffi.Int32,
);
typedef _ConvertDart = ffi.Pointer<Utf8> Function(
  ffi.Pointer<_NativeSession>,
  ffi.Pointer<Utf8>,
  int,
  int,
);
typedef _FreeSessionNative = ffi.Void Function(ffi.Pointer<_NativeSession>);
typedef _FreeSessionDart = void Function(ffi.Pointer<_NativeSession>);
typedef _StringNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _StringDart = void Function(ffi.Pointer<Utf8>);
typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();

/// Direct Linux/Windows adapter over converter-ffi; no HTTP or Python runtime.
final class DesktopEmbeddedConverter extends UnavailableEmbeddedConverter {
  DesktopEmbeddedConverter({ffi.DynamicLibrary? library})
    : _library = library ?? _openLibrary() {
    _open = _library.lookupFunction<_OpenNative, _OpenDart>('converter_session_open');
    _metadata = _library.lookupFunction<_MetadataNative, _MetadataDart>(
      'converter_session_metadata_json',
    );
    _convert = _library.lookupFunction<_ConvertNative, _ConvertDart>(
      'converter_session_convert_json',
    );
    _freeSession = _library.lookupFunction<_FreeSessionNative, _FreeSessionDart>(
      'converter_session_free',
    );
    _freeString = _library.lookupFunction<_StringNative, _StringDart>(
      'converter_string_free',
    );
    _lastError = _library.lookupFunction<_LastErrorNative, _LastErrorDart>(
      'converter_last_error',
    );
  }

  final ffi.DynamicLibrary _library;
  late final _OpenDart _open;
  late final _MetadataDart _metadata;
  late final _ConvertDart _convert;
  late final _FreeSessionDart _freeSession;
  late final _StringDart _freeString;
  late final _LastErrorDart _lastError;

  static ffi.DynamicLibrary _openLibrary() {
    final override = Platform.environment['EPUB2MP3_CONVERTER_FFI'];
    if (override != null && override.isNotEmpty) {
      return ffi.DynamicLibrary.open(override);
    }
    if (Platform.isWindows) return ffi.DynamicLibrary.open('converter_ffi.dll');
    if (Platform.isMacOS) return ffi.DynamicLibrary.open('libconverter_ffi.dylib');
    return ffi.DynamicLibrary.open('libconverter_ffi.so');
  }

  String _error() {
    final pointer = _lastError();
    if (pointer == ffi.nullptr) return 'converter-ffi operation failed';
    final value = pointer.toDartString();
    _freeString(pointer);
    return value;
  }

  T _withSession<T>(String path, T Function(ffi.Pointer<_NativeSession>) action) {
    final pathPtr = path.toNativeUtf8();
    try {
      final session = _open(pathPtr);
      if (session == ffi.nullptr) throw EmbeddedConversionFailure('RUST_OPEN_FAILED', _error());
      try {
        return action(session);
      } finally {
        _freeSession(session);
      }
    } finally {
      calloc.free(pathPtr);
    }
  }

  String _readString(ffi.Pointer<Utf8> pointer) {
    if (pointer == ffi.nullptr) throw EmbeddedConversionFailure('RUST_FAILED', _error());
    final value = pointer.toDartString();
    _freeString(pointer);
    return value;
  }

  @override
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) async {
    return _withSession(inputPath, (session) {
      final raw = _readString(_metadata(session));
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (jobId.isNotEmpty) decoded['jobId'] = jobId;
      return EbookFulltext.fromJson(decoded);
    });
  }

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    int? chapterStart,
    int? chapterEnd,
  }) async {
    return _withSession(inputPath, (session) {
      final outputPtr = outputPath.toNativeUtf8();
      try {
        final raw = _readString(
          _convert(session, outputPtr, chapterStart ?? -1, chapterEnd ?? -1),
        );
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> && decoded['manifest'] is Map) {
          return jsonEncode(decoded['manifest']);
        }
        return raw;
      } finally {
        calloc.free(outputPtr);
      }
    });
  }
}
