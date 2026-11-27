part of 'desktop_embedded_converter.dart';

typedef _ChapterNamesNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
);

/// Reads (`index == null`), sets or resets (`name == null`) a chapter name override in the
/// Rust-owned overrides file at [path]. Returns `{"names": {chapterIndex: name}}` or null
/// when the library or the file cannot be used.
Future<String?> desktopChapterNamesJson(
  String path, {
  String? index,
  String? name,
  String? libraryPath,
}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() => _updateChapterNames(library, path, index, name));
}

String? _updateChapterNames(
  String libraryPath,
  String path,
  String? index,
  String? name,
) {
  final library = ffi.DynamicLibrary.open(libraryPath);
  final update = library
      .lookupFunction<_ChapterNamesNative, _ChapterNamesNative>(
        'converter_chapter_names_update_json_v1',
      );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final nativePath = path.toNativeUtf8();
  final nativeIndex = index?.toNativeUtf8() ?? ffi.nullptr;
  final nativeName = name?.toNativeUtf8() ?? ffi.nullptr;
  try {
    final result = update(nativePath, nativeIndex, nativeName);
    if (result == ffi.nullptr) return null;
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  } finally {
    malloc.free(nativePath);
    if (nativeIndex != ffi.nullptr) malloc.free(nativeIndex);
    if (nativeName != ffi.nullptr) malloc.free(nativeName);
  }
}
