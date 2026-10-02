import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';

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
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''});
  Future<String> convert({
    required String inputPath,
    required String outputPath,
  });
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

/// The Android implementation invokes the registered native converter through
/// the platform channel. It never falls back to HTTP.
class AndroidEmbeddedConverter implements EmbeddedConverter {
  AndroidEmbeddedConverter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'epub_to_mp3/embedded_converter';
  final MethodChannel _channel;

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
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) {
    throw EmbeddedConverterUnavailable();
  }

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
  }) {
    throw EmbeddedConverterUnavailable();
  }

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
