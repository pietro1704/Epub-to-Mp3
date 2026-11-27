part of 'desktop_embedded_converter.dart';

typedef _FilenameCoverNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

/// Asks Rust for the filename cover contract (`{label, backgroundRgb}`) of [fileName]; null
/// when the library cannot be used.
Future<String?> desktopFilenameCoverJson(
  String fileName, {
  String? libraryPath,
}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() => _filenameCover(library, fileName));
}

String? _filenameCover(String libraryPath, String fileName) {
  final library = ffi.DynamicLibrary.open(libraryPath);
  final cover = library
      .lookupFunction<_FilenameCoverNative, _FilenameCoverNative>(
        'converter_filename_cover_json_v1',
      );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final nativeName = fileName.toNativeUtf8();
  try {
    final result = cover(nativeName);
    if (result == ffi.nullptr) return null;
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  } finally {
    malloc.free(nativeName);
  }
}
