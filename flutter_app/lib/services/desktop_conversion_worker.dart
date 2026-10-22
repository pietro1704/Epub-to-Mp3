part of 'desktop_embedded_converter.dart';

/// Only strings and integers cross the worker boundary.
class DesktopConversionRequest {
  const DesktopConversionRequest({
    required this.libraryPath,
    required this.inputPath,
    required this.outputPath,
    required this.chapterStart,
    required this.chapterEnd,
    required this.optionsJson,
    required this.controlAddress,
    this.streaming = false,
  });
  final String libraryPath, inputPath, outputPath, optionsJson;
  final int chapterStart, chapterEnd, controlAddress;
  final bool streaming;
}

Future<String> runDesktopConversionWorker(DesktopConversionRequest request) =>
    Isolate.run(() => _convertOnWorker(request));

String _convertOnWorker(DesktopConversionRequest request) {
  final options = Map<String, dynamic>.from(
    jsonDecode(request.optionsJson) as Map,
  );
  if (options['espeak_data_directory'] == null) {
    final dataParent = Directory(
      '${File(Platform.resolvedExecutable).parent.path}/data',
    );
    if (File('${dataParent.path}/espeak-ng-data/phontab').existsSync()) {
      options['espeak_data_directory'] = dataParent.path;
    }
  }
  final library = ffi.DynamicLibrary.open(request.libraryPath);
  final open = library.lookupFunction<_OpenNative, _OpenDart>(
    'converter_session_open',
  );
  final close = library.lookupFunction<_FreeSessionNative, _FreeSessionDart>(
    'converter_session_free',
  );
  final free = library.lookupFunction<_StringNative, _StringDart>(
    'converter_string_free',
  );
  final error = library.lookupFunction<_LastErrorNative, _LastErrorDart>(
    'converter_last_error',
  );
  String readOwned(ffi.Pointer<Utf8> value) {
    if (value == ffi.nullptr) {
      final detail = error();
      final message = detail == ffi.nullptr
          ? 'Rust desktop conversion failed'
          : detail.toDartString();
      if (detail != ffi.nullptr) free(detail);
      throw EmbeddedConversionFailure('RUST_FAILED', message);
    }
    try {
      return value.toDartString();
    } finally {
      free(value);
    }
  }

  return using((arena) {
    final session = open(request.inputPath.toNativeUtf8(allocator: arena));
    if (session == ffi.nullptr) return readOwned(ffi.nullptr);
    try {
      if (!_installDesktopPlatformSpeech(library, session, options)) {
        return readOwned(ffi.nullptr);
      }
      final output = request.outputPath.toNativeUtf8(allocator: arena);
      // The explicit Rust FFI owns the directory named by this exact job ID.
      final jobId = Directory(request.outputPath)
          .absolute.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
      final job = jobId.toNativeUtf8(allocator: arena);
      final captured = jsonEncode(options).toNativeUtf8(allocator: arena);
      final control = ffi.Pointer<ffi.Void>.fromAddress(request.controlAddress);
      if (request.streaming) {
        final convert = library
            .lookupFunction<_StreamingConvertNative, _StreamingConvertDart>(
              'converter_session_convert_streaming_job_options_json_v1',
            );
        return readOwned(
          convert(
            session,
            output,
            job,
            captured,
            request.chapterStart,
            request.chapterEnd,
            ffi.nullptr,
            ffi.nullptr,
            ffi.nullptr,
            ffi.nullptr,
            control,
          ),
        );
      }
      final convert = library.lookupFunction<_ConvertNative, _ConvertDart>(
        'converter_session_convert_controlled_job_options_json_v1',
      );
      return readOwned(
        convert(
          session,
          output,
          job,
          captured,
          request.chapterStart,
          request.chapterEnd,
          ffi.nullptr,
          ffi.nullptr,
          ffi.nullptr,
          control,
        ),
      );
    } finally {
      close(session);
    }
  });
}

Future<EbookFulltext> runDesktopParseWorker(
  String libraryPath,
  String inputPath,
  String jobId,
) => Isolate.run(
  () => DesktopEmbeddedConverter(
    libraryPath: libraryPath,
  )._parseSync(inputPath, jobId),
);

Future<String> runDesktopModelInstallWorker(
  String libraryPath,
  String modelId,
  String root,
) => Isolate.run(
  () => DesktopTtsModelAdapter(
    library: ffi.DynamicLibrary.open(libraryPath),
  ).installFromCatalog(modelId: modelId, root: root),
);
