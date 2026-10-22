import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';
import 'embedded_conversion_contract.dart';
import 'embedded_conversion_result.dart';
import 'edge_web_tts.dart';
import 'growing_chapter_audio_source.dart';
import 'android_speech_fallback.dart';

part 'android_conversion_model_channels.dart';

final _androidChunkEvents = const EventChannel(
  'epub_to_mp3/audio_chunks',
).receiveBroadcastStream();

/// The Android implementation invokes the registered native converter through
/// the platform channel. It never falls back to HTTP.
class AndroidEmbeddedConverter
    with _AndroidConversionModelChannels
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
  @override
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

}
