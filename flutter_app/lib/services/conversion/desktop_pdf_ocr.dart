part of 'desktop_embedded_converter.dart';

typedef _PdfOcrPagesNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _PdfOcrSetNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
);

/// `{"pages": [n, ...]}`: the PDF pages a platform OCR must read; null when unusable.
Future<String?> desktopPdfImagePagesJson(String path, {String? libraryPath}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() {
    final lib = ffi.DynamicLibrary.open(library);
    final pages = lib.lookupFunction<_PdfOcrPagesNative, _PdfOcrPagesNative>(
      'converter_pdf_image_pages_json_v1',
    );
    final free = lib.lookupFunction<_StringNative, _StringDart>(
      'converter_string_free',
    );
    final nativePath = path.toNativeUtf8();
    try {
      final result = pages(nativePath);
      if (result == ffi.nullptr) return null;
      try {
        return result.toDartString();
      } finally {
        free(result);
      }
    } finally {
      malloc.free(nativePath);
    }
  });
}

/// Stores the OCR text of one 1-based PDF page in the Rust-owned sidecar; blank text clears.
Future<String?> desktopPdfOcrPageSet(
  String path,
  int page,
  String? text, {
  String? libraryPath,
}) {
  final library = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
  return Isolate.run(() {
    final lib = ffi.DynamicLibrary.open(library);
    final set = lib.lookupFunction<_PdfOcrSetNative, _PdfOcrSetNative>(
      'converter_pdf_ocr_page_set_json_v1',
    );
    final free = lib.lookupFunction<_StringNative, _StringDart>(
      'converter_string_free',
    );
    final nativePath = path.toNativeUtf8();
    final nativePage = '$page'.toNativeUtf8();
    final nativeText = text?.toNativeUtf8() ?? ffi.nullptr;
    try {
      final result = set(nativePath, nativePage, nativeText);
      if (result == ffi.nullptr) return null;
      try {
        return result.toDartString();
      } finally {
        free(result);
      }
    } finally {
      malloc.free(nativePath);
      malloc.free(nativePage);
      if (nativeText != ffi.nullptr) malloc.free(nativeText);
    }
  });
}
