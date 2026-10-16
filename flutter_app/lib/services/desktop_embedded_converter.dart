import 'dart:convert';
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform, File, Directory;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';
import 'growing_chapter_audio_source.dart';
import 'desktop_tts_model_adapter.dart';
import '../models/tts_preferences.dart';

final class _NativeSession extends ffi.Opaque {}

typedef _OpenNative = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _OpenDart = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _MetadataNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _MetadataDart = ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _ConvertNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _ConvertDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _FreeSessionNative = ffi.Void Function(ffi.Pointer<_NativeSession>);
typedef _FreeSessionDart = void Function(ffi.Pointer<_NativeSession>);
typedef _StringNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _StringDart = void Function(ffi.Pointer<Utf8>);
typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();

/// Direct Linux/Windows adapter over converter-ffi; no HTTP or Python runtime.
final class DesktopEmbeddedConverter extends UnavailableEmbeddedConverter
    implements CancellableEmbeddedConverter, StreamingChapterConverter {
  DesktopEmbeddedConverter({ffi.DynamicLibrary? library, String? libraryPath})
    : _libraryPath = libraryPath ?? _resolveLibraryPath(),
      _workerLibraryAvailable = library == null || libraryPath != null,
      _library =
          library ??
          ffi.DynamicLibrary.open(libraryPath ?? _resolveLibraryPath()) {
    _open = _library.lookupFunction<_OpenNative, _OpenDart>(
      'converter_session_open',
    );
    _metadata = _library.lookupFunction<_MetadataNative, _MetadataDart>(
      'converter_session_metadata_json',
    );
    _freeSession = _library
        .lookupFunction<_FreeSessionNative, _FreeSessionDart>(
          'converter_session_free',
        );
    _freeString = _library.lookupFunction<_StringNative, _StringDart>(
      'converter_string_free',
    );
    _lastError = _library.lookupFunction<_LastErrorNative, _LastErrorDart>(
      'converter_last_error',
    );
  }

  late final DesktopTtsModelAdapter _models = DesktopTtsModelAdapter(
    library: _library,
  );
  final ffi.DynamicLibrary _library;
  late final _OpenDart _open;
  late final _MetadataDart _metadata;
  final String _libraryPath;
  final bool _workerLibraryAvailable;
  final Map<String, int> _controls = {};
  final Map<String, GrowingChapterAudioSource> _streams = {};
  Future<void> _queue = Future<void>.value();
  late final _FreeSessionDart _freeSession;
  late final _StringDart _freeString;
  late final _LastErrorDart _lastError;

  static String _resolveLibraryPath() {
    final override = Platform.environment['EPUB2MP3_CONVERTER_FFI'];
    if (override != null && override.isNotEmpty) return override;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) return '$executableDirectory/converter_ffi.dll';
    if (Platform.isMacOS) return 'libconverter_ffi.dylib';
    return '$executableDirectory/lib/libconverter_ffi.so';
  }

  @override
  Future<String> ttsModels() async => _models.modelsJson();
  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) async {
    _requireWorkerLibrary();
    final libraryPath = _libraryPath;
    return _enqueueWorker(
      () => runDesktopModelInstallWorker(libraryPath, modelId, root),
    );
  }

  @override
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) async => _models.remove(modelId: modelId, root: root);
  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => _models.metadata(modelId: modelId, root: root);

  /// Cancellation shares only a native control address, never an isolate-owned session.
  @override
  Future<void> cancelConversion({String? inputPath, String? outputPath}) async {
    if (outputPath == null) return;
    final address = _controls[outputPath];
    if (address == null) return;
    _library.lookupFunction<_ControlActionNative, _ControlActionDart>(
      'converter_job_control_cancel',
    )(ffi.Pointer.fromAddress(address));
  }

  void _requireWorkerLibrary() {
    if (!_workerLibraryAvailable) {
      throw EmbeddedConverterUnavailable(
        'Injected desktop libraries require a libraryPath for worker operations',
      );
    }
  }

  Future<T> _enqueueWorker<T>(Future<T> Function() launch) {
    final result = _queue.then((_) => launch());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<String> _runConversion(
    String input,
    String output,
    int start,
    int end,
    String? options, {
    Future<void> Function(Map<String, dynamic>)? onChunk,
  }) async {
    _requireWorkerLibrary();
    if (_controls.containsKey(output)) {
      throw EmbeddedConversionFailure(
        'CONVERSION_BUSY',
        'An active conversion already owns this output directory',
      );
    }
    final freeControl = _library
        .lookupFunction<_ControlActionNative, _ControlActionDart>(
          'converter_job_control_free',
        );
    final control = _library
        .lookupFunction<_ControlCreateNative, _ControlCreateDart>(
          'converter_job_control_create',
        )();
    if (control == ffi.nullptr) {
      throw EmbeddedConversionFailure('CONTROL_UNAVAILABLE', _error());
    }
    _controls[output] = control.address;
    final request = DesktopConversionRequest(
      libraryPath: _libraryPath,
      inputPath: input,
      outputPath: output,
      chapterStart: start,
      chapterEnd: end,
      optionsJson: options ?? const TtsPreferences().optionsJson(),
      controlAddress: control.address,
      streaming: onChunk != null,
    );
    Timer? polling;
    Future<void>? currentDrain;
    Object? chunkFailure;
    Future<void> drainChunks() async {
      if (onChunk == null || chunkFailure != null) return;
      try {
        final take = _library
            .lookupFunction<_ControlChunkTakeNative, _ControlChunkTakeDart>(
              'converter_job_control_take_audio_chunk_json',
            );
        while (true) {
          final pointer = take(control);
          if (pointer == ffi.nullptr) break;
          final event = Map<String, dynamic>.from(
            jsonDecode(_readString(pointer)) as Map,
          );
          if (event['error'] != null) {
            throw EmbeddedConversionFailure(
              'CHUNK_DELIVERY_FAILED',
              '${event['error']}',
            );
          }
          await onChunk(event);
        }
      } catch (error) {
        chunkFailure = error;
        await cancelConversion(outputPath: output);
      }
    }

    try {
      if (onChunk != null) {
        final enabled = _library
            .lookupFunction<_ControlChunkEnableNative, _ControlChunkEnableDart>(
              'converter_job_control_enable_audio_chunks',
            )(control);
        if (!enabled) {
          throw EmbeddedConversionFailure(
            'STREAM_UNAVAILABLE',
            'Rust audio chunk queue could not be enabled',
          );
        }
        polling = Timer.periodic(const Duration(milliseconds: 20), (_) {
          currentDrain ??= drainChunks().whenComplete(
            () => currentDrain = null,
          );
        });
      }
    } catch (_) {
      _controls.remove(output);
      freeControl(control);
      rethrow;
    }
    final result = _enqueueWorker(() => runDesktopConversionWorker(request));
    try {
      final raw = await result;
      polling?.cancel();
      await currentDrain;
      await drainChunks();
      if (chunkFailure != null) throw chunkFailure!;
      return raw;
    } finally {
      polling?.cancel();
      await currentDrain;
      _controls.remove(output);
      freeControl(control);
    }
  }

  String _error() {
    final pointer = _lastError();
    if (pointer == ffi.nullptr) return 'converter-ffi operation failed';
    final value = pointer.toDartString();
    _freeString(pointer);
    return value;
  }

  T _withSession<T>(
    String path,
    T Function(ffi.Pointer<_NativeSession>) action,
  ) {
    final pathPtr = path.toNativeUtf8();
    try {
      final session = _open(pathPtr);
      if (session == ffi.nullptr) {
        throw EmbeddedConversionFailure('RUST_OPEN_FAILED', _error());
      }
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
    if (pointer == ffi.nullptr) {
      throw EmbeddedConversionFailure('RUST_FAILED', _error());
    }
    final value = pointer.toDartString();
    _freeString(pointer);
    return value;
  }

  @override
  Future<EbookFulltext> parse({
    required String inputPath,
    String jobId = '',
  }) async {
    _requireWorkerLibrary();
    final libraryPath = _libraryPath;
    return _enqueueWorker(
      () => runDesktopParseWorker(libraryPath, inputPath, jobId),
    );
  }

  EbookFulltext _parseSync(String inputPath, String jobId) {
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
    String? optionsJson,
  }) async {
    final raw = await _runConversion(
      inputPath,
      outputPath,
      chapterStart ?? -1,
      chapterEnd ?? -1,
      optionsJson,
    );
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic> && decoded['manifest'] is Map) {
      return jsonEncode(decoded['manifest']);
    }
    return raw;
  }

  @override
  Future<ConvertedChapterAudio> streamChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
    required Future<void> Function(GrowingChapterAudioSource) onFirstAudio,
  }) async {
    if (_streams.containsKey(outputPath)) {
      throw EmbeddedConversionFailure(
        'CONVERSION_BUSY',
        'An active stream already owns this output directory',
      );
    }
    final source = GrowingChapterAudioSource(outputPath);
    _streams[outputPath] = source;
    var delivered = false;
    try {
      final raw = await _runConversion(
        inputPath,
        outputPath,
        chapterIndex,
        chapterIndex,
        optionsJson,
        onChunk: (event) async {
          if (event['chapterIndex'] != chapterIndex) {
            throw EmbeddedConversionFailure(
              'CHAPTER_INDEX_MISMATCH',
              'Rust published a chunk for another chapter',
            );
          }
          await source.append(
            (event['chunkIndex'] as num).toInt(),
            event['path'] as String,
          );
          if (!delivered && source.chunkCount > 0) {
            delivered = true;
            await onFirstAudio(source);
          }
        },
      );
      if (!delivered) {
        throw EmbeddedConversionFailure(
          'EMPTY_CHAPTER_STREAM',
          'Rust returned no playable audio chunks',
        );
      }
      final result = ConvertedChapterAudio.fromNativeResult(
        raw,
        expectedChapterIndex: chapterIndex,
      );
      source.complete();
      return result;
    } catch (error) {
      source.fail(error);
      rethrow;
    } finally {
      _streams.remove(outputPath);
    }
  }

  @override
  Future<void> cancelStreamingChapter(String outputPath) async {
    _streams[outputPath]?.fail(StateError('Chapter stream cancelled'));
    await cancelConversion(outputPath: outputPath);
  }

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    final raw = await _runConversion(
      inputPath,
      outputPath,
      chapterIndex,
      chapterIndex,
      optionsJson,
    );
    return ConvertedChapterAudio.fromNativeResult(
      raw,
      expectedChapterIndex: chapterIndex,
    );
  }
}

typedef _ControlCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _ControlCreateDart = ffi.Pointer<ffi.Void> Function();
typedef _ControlActionNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ControlActionDart = void Function(ffi.Pointer<ffi.Void>);

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
      final output = request.outputPath.toNativeUtf8(allocator: arena);
      final job = 'flutter-${DateTime.now().microsecondsSinceEpoch}'
          .toNativeUtf8(allocator: arena);
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

typedef _ControlChunkEnableNative = ffi.Bool Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkEnableDart = bool Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkTakeNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkTakeDart =
    ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _StreamingConvertNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _StreamingConvertDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
