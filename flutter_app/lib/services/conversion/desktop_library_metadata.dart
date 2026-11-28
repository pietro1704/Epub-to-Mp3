part of 'desktop_embedded_converter.dart';

typedef _LibraryMetadataNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _LibraryMetadataDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

/// Library-shelf metadata JSON from converter-ffi, read on a background isolate
/// so a slow archive cannot block the UI. Returns null when the library or the
/// book cannot be read.
Future<String?> desktopLibraryMetadataJson(String path, {String? libraryPath}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() => _readLibraryMetadata(library, path));
}

String? _readLibraryMetadata(String libraryPath, String path) {
  final library = ffi.DynamicLibrary.open(libraryPath);
  final read = library.lookupFunction<_LibraryMetadataNative, _LibraryMetadataDart>(
    'converter_book_library_metadata_json_v1',
  );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final nativePath = path.toNativeUtf8();
  try {
    final result = read(nativePath);
    if (result == ffi.nullptr) return null;
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  } finally {
    malloc.free(nativePath);
  }
}

/// Batch shelf JSON (`converter_book_library_shelf_json_v1`) read on a background isolate.
/// Returns null when the library or the request cannot be read.
Future<String?> desktopLibraryShelfJson(String requestJson, {String? libraryPath}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() => _readLibraryShelf(library, requestJson));
}

String? _readLibraryShelf(String libraryPath, String requestJson) {
  final library = ffi.DynamicLibrary.open(libraryPath);
  final read = library.lookupFunction<_LibraryMetadataNative, _LibraryMetadataDart>(
    'converter_book_library_shelf_json_v1',
  );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final nativeRequest = requestJson.toNativeUtf8();
  try {
    final result = read(nativeRequest);
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
