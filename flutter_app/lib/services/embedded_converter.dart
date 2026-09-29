import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';

/// Selects the implementation used for local conversion.
enum ConverterMode { embedded, http }

/// Raised when embedded conversion was explicitly requested but no native
/// converter-ffi implementation has been registered for this process.
class EmbeddedConverterUnavailable extends Error {
  EmbeddedConverterUnavailable([this.message = 'converter-ffi runtime is unavailable']);

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
      throw EmbeddedConversionFailure(
        status['modelAvailable'] == false ? 'MODEL_MISSING' : 'RUNTIME_UNAVAILABLE',
        'Embedded Piper is not ready: $status',
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
      await ensureRuntimeLoaded();
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
      if (decoded is Map<String, dynamic> && decoded['audioPath'] is String) {
        return decoded['audioPath'] as String;
      }
      if (decoded is Map<String, dynamic> && decoded['chapters'] is List) {
        final chapters = decoded['chapters'] as List;
        if (chapters.isNotEmpty && chapters.first is Map<String, dynamic>) {
          final filename = (chapters.first as Map<String, dynamic>)['filename'];
          if (filename is String) return filename;
        }
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
