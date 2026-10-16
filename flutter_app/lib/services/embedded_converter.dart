import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';
import '../models/tts_preferences.dart';
import 'edge_web_tts.dart';
import 'growing_chapter_audio_source.dart';
import 'android_speech_fallback.dart';

/// Selects the implementation used for local conversion.
enum ConverterMode { embedded, http }

/// Raised when embedded conversion was explicitly requested but no native
/// converter-ffi implementation has been registered for this process.
class EmbeddedConverterUnavailable extends Error {
  EmbeddedConverterUnavailable([
    this.message = 'converter-ffi runtime is unavailable',
  ]);

  final String message;

  @override
  String toString() => 'EmbeddedConverterUnavailable: $message';
}

class EmbeddedConversionFailure extends Error {
  EmbeddedConversionFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'EmbeddedConversionFailure($code): $message';
}

/// Platform-neutral seam for the converter-ffi C ABI.
abstract interface class EmbeddedConverter {
  Future<Uint8List> edgeProbe(String text, {String? locale}) =>
      throw EmbeddedConverterUnavailable(
        'Android Edge transport probe is unavailable',
      );
  Future<void> speakFallback(String text, {required String locale}) =>
      throw EmbeddedConverterUnavailable(
        'Android speech fallback is unavailable',
      );
  Future<String> synthesizeFallback(
    String text, {
    required String locale,
    required String path,
  }) => throw EmbeddedConverterUnavailable(
    'Android audio synthesis fallback is unavailable',
  );
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''});
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    int? chapterStart,
    int? chapterEnd,
    String? optionsJson,
  });
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) => throw EmbeddedConverterUnavailable(
    'Rust chapter conversion is unavailable',
  );
  Future<String> ttsModels() =>
      throw EmbeddedConverterUnavailable('TTS model catalog is unavailable');
  Future<String> ttsDefaultEngine({
    required String language,
    required String platform,
    int? androidApi,
  }) =>
      throw EmbeddedConverterUnavailable('TTS engine selection is unavailable');
  Future<String> ttsInstalledReadyEngine({
    required String language,
    required String platform,
    required String installedModelIdsJson,
    required String readyModelIdsJson,
    int? androidApi,
  }) => throw EmbeddedConverterUnavailable(
    'Validated TTS engine selection is unavailable',
  );
  Future<String> installTtsModel({
    required String modelId,
    required String url,
    required String sha256,
    required String root,
  }) => throw EmbeddedConverterUnavailable(
    'TTS model installation is unavailable',
  );
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable('TTS model removal is unavailable');
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable('TTS model metadata is unavailable');
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable(
    'Catalog TTS model installation is unavailable',
  );
}

class ConvertedChapterAudio {
  const ConvertedChapterAudio({
    required this.chapterIndex,
    required this.path,
    required this.title,
    this.usedSelections = const [],
    this.fallbackUsed = false,
    this.ttsPolicyState,
  });

  final List<TtsSelection> usedSelections;
  final bool fallbackUsed;
  final Map<String, dynamic>? ttsPolicyState;
  final int chapterIndex;
  final String path;
  final String title;

  static ConvertedChapterAudio fromNativeResult(
    String raw, {
    required int expectedChapterIndex,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['audioPath'] is! String) {
      throw EmbeddedConversionFailure(
        'INVALID_CHAPTER_RESULT',
        'Rust converter returned no chapter audio path',
      );
    }
    final manifest = decoded['manifest'];
    final entries = manifest is Map ? manifest['chapters'] : null;
    if (entries is! List || entries.length != 1 || entries.single is! Map) {
      throw EmbeddedConversionFailure(
        'INVALID_CHAPTER_RESULT',
        'Rust converter did not return exactly one requested chapter',
      );
    }
    final entry = Map<String, dynamic>.from(entries.single as Map);
    final sourceIndex = entry['sourceIndex'];
    if (sourceIndex is! num || sourceIndex.toInt() != expectedChapterIndex) {
      throw EmbeddedConversionFailure(
        'CHAPTER_INDEX_MISMATCH',
        'Rust returned an unexpected source chapter for request $expectedChapterIndex',
      );
    }
    return ConvertedChapterAudio(
      chapterIndex: expectedChapterIndex,
      path: decoded['audioPath'] as String,
      title: entry['title'] as String? ?? '',
      fallbackUsed: manifest['fallbackUsed'] == true,
      usedSelections: (manifest['usedSelections'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (selection) =>
                TtsSelection.fromJson(Map<String, dynamic>.from(selection)),
          )
          .toList(growable: false),
      ttsPolicyState: manifest['ttsPolicyState'] is Map
          ? Map<String, dynamic>.from(manifest['ttsPolicyState'] as Map)
          : null,
    );
  }
}

/// The Android implementation invokes the registered native converter through
/// the platform channel. It never falls back to HTTP.
abstract interface class CancellableEmbeddedConverter {
  Future<void> cancelConversion({String? inputPath, String? outputPath});
}

abstract interface class StreamingChapterConverter {
  Future<ConvertedChapterAudio> streamChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
    required Future<void> Function(GrowingChapterAudioSource) onFirstAudio,
  });
  Future<void> cancelStreamingChapter(String outputPath);
}

final _androidChunkEvents = const EventChannel(
  'epub_to_mp3/audio_chunks',
).receiveBroadcastStream();

class AndroidEmbeddedConverter
    implements
        EmbeddedConverter,
        StreamingChapterConverter,
        CancellableEmbeddedConverter {
  AndroidEmbeddedConverter({
    MethodChannel? channel,
    Stream<dynamic>? chunkEvents,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _chunkEvents = chunkEvents ?? _androidChunkEvents;

  static const channelName = 'epub_to_mp3/embedded_converter';
  final MethodChannel _channel;
  final Stream<dynamic> _chunkEvents;
  final Map<String, GrowingChapterAudioSource> _liveStreams = {};
  final Set<String> _cancelledStreams = {};
  final EdgeWebTts _edge = EdgeWebTts();
  final AndroidSpeechFallback _speechFallback = AndroidSpeechFallback();

  @override
  Future<void> cancelConversion({String? inputPath, String? outputPath}) async {
    try {
      final arguments = <String, String>{};
      if (inputPath != null) arguments['inputPath'] = inputPath;
      if (outputPath != null) arguments['outputPath'] = outputPath;
      await _channel.invokeMethod<void>('cancelConversion', arguments);
    } on MissingPluginException {
      // Older platform builds have no cancellation entry point.
    } on PlatformException {
      // The activity may already have exited.
    }
  }

  @override
  Future<void> cancelStreamingChapter(String outputPath) async {
    final source = _liveStreams[outputPath];
    if (source != null) {
      _cancelledStreams.add(outputPath);
      source.fail(StateError('Chapter stream cancelled'));
    }
    await cancelConversion(outputPath: outputPath);
  }

  @override
  Future<ConvertedChapterAudio> streamChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
    required Future<void> Function(GrowingChapterAudioSource) onFirstAudio,
  }) async {
    final source = GrowingChapterAudioSource(outputPath);
    _liveStreams[outputPath] = source;
    void checkActive() {
      if (_cancelledStreams.contains(outputPath)) {
        throw StateError('Chapter stream cancelled');
      }
    }

    Future<void> events = Future.value();
    Object? eventError;
    var accepting = true;
    var delivered = false;
    final subscription = _chunkEvents.listen(
      (event) {
        if (!accepting ||
            event is! Map ||
            event['requestId'] != outputPath ||
            event['chapterIndex'] != chapterIndex) {
          return;
        }
        events = events
            .then((_) async {
              if (!accepting || eventError != null || source.isComplete) return;
              await source.append(
                event['chunkIndex'] as int,
                event['path'] as String,
              );
              if (!delivered && source.chunkCount > 0) {
                delivered = true;
                await onFirstAudio(source);
              }
            })
            .catchError((Object error) {
              eventError = error;
              source.fail(error);
            });
      },
      onError: (Object error) {
        eventError = error;
        source.fail(error);
      },
    );
    try {
      await ensureRuntimeLoaded();
      checkActive();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await _channel.invokeMethod<bool>('streamReady') != true) {
        checkActive();
        if (DateTime.now().isAfter(deadline)) {
          throw EmbeddedConversionFailure(
            'STREAM_UNAVAILABLE',
            'Android streaming listener is unavailable',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      checkActive();
      final raw = await _channel.invokeMethod<String>('convert', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'optionsJson': ?optionsJson,
        'chapterStart': chapterIndex,
        'chapterEnd': chapterIndex,
        'streaming': true,
      });
      await events;
      checkActive();
      if (eventError != null) throw eventError!;
      if (raw == null || !delivered) {
        throw EmbeddedConversionFailure(
          'EMPTY_CHAPTER_STREAM',
          'Rust returned no streaming chapter audio',
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
      await cancelStreamingChapter(outputPath);
      rethrow;
    } finally {
      accepting = false;
      await subscription.cancel();
      _liveStreams.remove(outputPath);
      _cancelledStreams.remove(outputPath);
    }
  }

  @override
  Future<Uint8List> edgeProbe(String text, {String? locale}) async {
    final normalized = (locale ?? 'en-US').replaceAll('_', '-');
    final voice = normalized.toLowerCase().startsWith('pt')
        ? 'pt-BR-AntonioNeural'
        : normalized.toLowerCase().startsWith('es')
        ? 'es-ES-AlvaroNeural'
        : 'en-US-GuyNeural';
    try {
      final raw = await _edge.synthesize(text, voice: voice);
      if (raw.isEmpty) {
        throw EmbeddedConversionFailure(
          'EDGE_PROBE_EMPTY',
          'Edge returned no audio',
        );
      }
      return raw;
    } on EmbeddedConversionFailure {
      rethrow;
    } catch (error) {
      throw EmbeddedConversionFailure('EDGE_PROBE_FAILED', '$voice: $error');
    }
  }

  @override
  Future<void> speakFallback(String text, {required String locale}) =>
      _speechFallback.speak(text, locale: locale);

  @override
  Future<String> synthesizeFallback(
    String text, {
    required String locale,
    required String path,
  }) async {
    try {
      final result = await const MethodChannel('epub_to_mp3/android_tts')
          .invokeMethod<String>('synthesizeToFile', {
            'text': text,
            'locale': locale,
            'path': path,
          })
          .timeout(const Duration(seconds: 90));
      if (result != null && result.isNotEmpty) return result;
    } on PlatformException catch (error) {
      throw EmbeddedConversionFailure(
        'TTS_SYNTHESIS_FAILED',
        error.message ?? error.code,
      );
    } on MissingPluginException catch (error) {
      throw EmbeddedConversionFailure('TTS_UNAVAILABLE', error.toString());
    }
    throw EmbeddedConversionFailure(
      'TTS_SYNTHESIS_EMPTY',
      'Android TTS returned no audio path',
    );
  }

  Future<Map<String, bool>> runtimeStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      if (raw == null) return const {};
      return raw.map((key, value) => MapEntry(key.toString(), value == true));
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  Future<bool> isRuntimeLoaded() async =>
      (await runtimeStatus())['runtimeLoaded'] == true;

  Future<void> ensureRuntimeLoaded() async {
    final status = await runtimeStatus();
    if (status['engineReady'] != true) {
      throw EmbeddedConverterUnavailable(
        'Embedded TTS runtime is not ready: $status',
      );
    }
  }

  @override
  Future<EbookFulltext> parse({
    required String inputPath,
    String jobId = '',
  }) async {
    try {
      await ensureRuntimeLoaded();
      final raw = await _channel.invokeMethod<String>('parse', {
        'inputPath': inputPath,
        'jobId': jobId,
      });
      if (raw == null || raw.isEmpty) {
        throw PlatformException(
          code: 'EMBEDDED_CONVERTER_UNAVAILABLE',
          message: 'converter-ffi returned no parsed book',
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Embedded converter returned invalid metadata',
        );
      }
      if (jobId.isNotEmpty) decoded['jobId'] = jobId;
      return EbookFulltext.fromJson(decoded);
    } on MissingPluginException {
      throw EmbeddedConverterUnavailable();
    } on PlatformException catch (error) {
      throw EmbeddedConversionFailure(
        error.code,
        error.message ?? 'embedded parse failed',
      );
    }
  }

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    int? chapterStart,
    int? chapterEnd,
    String? optionsJson,
  }) async {
    try {
      // ignore: avoid_print
      print('AndroidEmbeddedConverter: invoking native convert');
      await ensureRuntimeLoaded();
      // The native channel returns a manifest path or inline JSON. Keep the
      // request observable on Android while the Rust worker runs.
      // ignore: avoid_print
      print(
        'AndroidEmbeddedConverter: invoking native convert input=$inputPath output=$outputPath',
      );
      final result = await _channel.invokeMethod<String>('convert', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'optionsJson': ?optionsJson,
        'chapterStart': chapterStart ?? -1,
        'chapterEnd': chapterEnd ?? -1,
      });
      if (result == null || result.isEmpty) {
        throw PlatformException(
          code: 'EMBEDDED_CONVERTER_UNAVAILABLE',
          message: 'converter-ffi returned no result',
        );
      }
      final decoded = jsonDecode(result);
      if (decoded is Map<String, dynamic> && decoded['manifest'] is Map) {
        final manifest = Map<String, dynamic>.from(decoded['manifest'] as Map);
        final chapters = manifest['chapters'];
        if (chapters is! List || chapters.isEmpty) {
          throw EmbeddedConversionFailure(
            'EMPTY_MANIFEST',
            'Rust converter returned no chapters',
          );
        }
        return jsonEncode(manifest);
      }
      if (decoded is Map<String, dynamic> && decoded['audioPath'] is String) {
        final audioPath = decoded['audioPath'] as String;
        final manifestPath = decoded['manifestPath'];
        if (manifestPath is String && manifestPath.isNotEmpty) {
          return manifestPath;
        }
        return audioPath;
      }
      if (decoded is Map<String, dynamic> && decoded['chapters'] is List) {
        return result;
      }
      return result;
    } on MissingPluginException {
      throw EmbeddedConverterUnavailable();
    } on PlatformException catch (error) {
      throw EmbeddedConversionFailure(
        error.code,
        error.message ?? 'embedded conversion failed',
      );
    }
  }

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    try {
      await ensureRuntimeLoaded();
      final raw = await _channel.invokeMethod<String>('convert', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'optionsJson': ?optionsJson,
        'chapterStart': chapterIndex,
        'chapterEnd': chapterIndex,
      });
      if (raw == null || raw.isEmpty) {
        throw EmbeddedConversionFailure(
          'EMPTY_CHAPTER_RESULT',
          'Rust converter returned no chapter result',
        );
      }
      return ConvertedChapterAudio.fromNativeResult(
        raw,
        expectedChapterIndex: chapterIndex,
      );
    } on MissingPluginException {
      throw EmbeddedConverterUnavailable();
    } on PlatformException catch (error) {
      throw EmbeddedConversionFailure(
        error.code,
        error.message ?? 'embedded chapter conversion failed',
      );
    }
  }

  @override
  Future<String> ttsModels() async {
    final value = await _channel.invokeMethod<String>('ttsModels');
    if (value == null || value.isEmpty) {
      throw EmbeddedConverterUnavailable('empty TTS model catalog');
    }
    return value;
  }

  @override
  Future<String> ttsDefaultEngine({
    required String language,
    required String platform,
    int? androidApi,
  }) async {
    final value = await _channel.invokeMethod<String>('ttsDefaultEngine', {
      'language': language,
      'platform': platform,
      // ignore: use_null_aware_elements
      if (androidApi != null) 'androidApi': androidApi,
    });
    if (value == null || value.isEmpty) {
      throw EmbeddedConverterUnavailable('empty TTS engine selection');
    }
    return value;
  }

  @override
  Future<String> ttsInstalledReadyEngine({
    required String language,
    required String platform,
    required String installedModelIdsJson,
    required String readyModelIdsJson,
    int? androidApi,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'ttsInstalledReadyEngine',
      {
        'language': language,
        'platform': platform,
        'installedModelIdsJson': installedModelIdsJson,
        'readyModelIdsJson': readyModelIdsJson,
        // ignore: use_null_aware_elements
        if (androidApi != null) 'androidApi': androidApi,
      },
    );
    if (value == null || value.isEmpty) {
      throw EmbeddedConverterUnavailable(
        'empty validated TTS engine selection',
      );
    }
    return value;
  }

  @override
  Future<String> installTtsModel({
    required String modelId,
    required String url,
    required String sha256,
    required String root,
  }) async {
    final value = await _channel.invokeMethod<String>('ttsModelInstall', {
      'modelId': modelId,
      'url': url,
      'sha256': sha256,
      'root': root,
    });
    if (value == null || value.isEmpty) throw EmbeddedConverterUnavailable();
    return value;
  }

  Future<String> synthesizePiper({
    required String text,
    required String output,
    String? optionsJson,
  }) async {
    final value = await _channel.invokeMethod<String>('piperSynthesize', {
      'text': text,
      'output': output,
      'optionsJson': ?optionsJson,
    });
    if (value == null || value.isEmpty) throw EmbeddedConverterUnavailable();
    return value;
  }

  Future<String> installTtsModelManifest({
    required String modelId,
    required String artifactsJson,
    required String root,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'ttsModelInstallManifest',
      {'modelId': modelId, 'artifactsJson': artifactsJson, 'root': root},
    );
    if (value == null || value.isEmpty) throw EmbeddedConverterUnavailable();
    return value;
  }

  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'ttsModelInstallCatalogManifest',
      {'modelId': modelId, 'root': root},
    );
    if (value == null || value.isEmpty) throw EmbeddedConverterUnavailable();
    return value;
  }

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => await _channel.invokeMethod<String>('ttsModelMetadata', {
    'modelId': modelId,
    'root': root,
  });

  @override
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) async =>
      await _channel.invokeMethod<bool>('ttsModelRemove', {
        'modelId': modelId,
        'root': root,
      }) ??
      false;
}

class UnavailableEmbeddedConverter implements EmbeddedConverter {
  const UnavailableEmbeddedConverter();

  @override
  Future<Uint8List> edgeProbe(String text, {String? locale}) =>
      throw EmbeddedConverterUnavailable();

  @override
  Future<void> speakFallback(String text, {required String locale}) =>
      throw EmbeddedConverterUnavailable();

  @override
  Future<String> synthesizeFallback(
    String text, {
    required String locale,
    required String path,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) {
    throw EmbeddedConverterUnavailable();
  }

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    int? chapterStart,
    int? chapterEnd,
    String? optionsJson,
  }) {
    throw EmbeddedConverterUnavailable();
  }

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<String> ttsModels() => throw EmbeddedConverterUnavailable();

  @override
  Future<String> ttsDefaultEngine({
    required String language,
    required String platform,
    int? androidApi,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<String> ttsInstalledReadyEngine({
    required String language,
    required String platform,
    required String installedModelIdsJson,
    required String readyModelIdsJson,
    int? androidApi,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<String> installTtsModel({
    required String modelId,
    required String url,
    required String sha256,
    required String root,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable();

  @override
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) => throw EmbeddedConverterUnavailable();
}

/// Routes local conversion to embedded ffi or the explicit HTTP compatibility
/// path. Embedded mode never falls through to HTTP.
class LocalConverterAdapter {
  LocalConverterAdapter({
    required this.mode,
    this.embedded = const UnavailableEmbeddedConverter(),
    required this.httpFallback,
  });

  final ConverterMode mode;
  final EmbeddedConverter embedded;
  final Future<String> Function({
    required String inputPath,
    required String outputPath,
  })
  httpFallback;

  Future<String> convert({
    required String inputPath,
    required String outputPath,
  }) {
    switch (mode) {
      case ConverterMode.embedded:
        return embedded.convert(inputPath: inputPath, outputPath: outputPath);
      case ConverterMode.http:
        return httpFallback(inputPath: inputPath, outputPath: outputPath);
    }
  }
}

/// Process-local registration point used by platform integration code.
class EmbeddedConverterRegistry {
  EmbeddedConverterRegistry._();

  static EmbeddedConverter? _implementation;

  static EmbeddedConverter get current =>
      _implementation ?? const UnavailableEmbeddedConverter();

  static void register(EmbeddedConverter implementation) {
    _implementation = implementation;
  }

  static void clear() {
    _implementation = null;
  }
}
