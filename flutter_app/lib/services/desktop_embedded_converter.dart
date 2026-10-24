import 'dart:convert';
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform, File, Directory;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../models/ebook_fulltext.dart';
import 'embedded_converter.dart';
import 'growing_chapter_audio_source.dart';
import 'listening_schedule.dart';
import 'desktop_tts_model_adapter.dart';
import '../models/tts_preferences.dart';

part 'desktop_ffi_bindings.dart';
part 'desktop_listening_schedule.dart';
part 'desktop_positioned_chapter.dart';
part 'desktop_conversion_worker.dart';
part 'desktop_platform_speech.dart';

/// Direct Linux/Windows adapter over converter-ffi; no HTTP or Python runtime.
final class DesktopEmbeddedConverter extends UnavailableEmbeddedConverter
    implements CancellableEmbeddedConverter, StreamingChapterConverter, ListeningScheduleFactory, PositionedChapterConverter {
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
  ListeningSchedule createListeningSchedule(int initialChapterIndex) =>
      DesktopListeningSchedule(_library, initialChapterIndex);

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
    int? textOffset,
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
    if (textOffset != null) {
      try {
        using((arena) {
          final setPosition = _library.lookupFunction<_ControlJsonNative, _ControlJsonDart>(
            'converter_job_control_set_listening_position_json_v2');
          if (!setPosition(control, jsonEncode({'version':2, 'chapter_index':start,
            'text_offset':textOffset}).toNativeUtf8(allocator:arena))) {
            throw StateError('Rust rejected the requested source text range');
          }
        });
      } catch (_) { freeControl(control); rethrow; }
    }
    _controls[output] = control.address;
    final request = DesktopConversionRequest(
      libraryPath: _libraryPath,
      inputPath: input,
      outputPath: output,
      chapterStart: start,
      chapterEnd: end,
      optionsJson: options ?? const TtsPreferences.appDefaults().optionsJson(),
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
      decoded['jobId'] = jobId;
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
  Future<ConvertedChapterAudio> convertPositionedChapter({required String inputPath,
    required String outputPath, required int chapterIndex, required int textOffset,
    String? optionsJson, Future<void> Function(GrowingChapterAudioSource)? onFirstAudio}) =>
      _positionedChapter(inputPath: inputPath, outputPath: outputPath, chapterIndex: chapterIndex,
        textOffset: textOffset, optionsJson: optionsJson, onFirstAudio: onFirstAudio);

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
