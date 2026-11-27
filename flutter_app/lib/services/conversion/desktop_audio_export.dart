part of 'desktop_embedded_converter.dart';

/// Runs the Rust MP3 export for [requestJson]; returns the `{"files": [...]}` JSON, or null
/// when Rust refused the request.
Future<String?> desktopExportMp3Json(
  String requestJson, {
  String? libraryPath,
}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() => _exportMp3(library, requestJson));
}

String? _exportMp3(String libraryPath, String requestJson) {
  final library = ffi.DynamicLibrary.open(libraryPath);
  final export = library
      .lookupFunction<_FilenameCoverNative, _FilenameCoverNative>(
        'converter_export_mp3_json_v1',
      );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final nativeRequest = requestJson.toNativeUtf8();
  try {
    final result = export(nativeRequest);
    if (result == ffi.nullptr) return null;
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  } finally {
    malloc.free(nativeRequest);
  }
}
