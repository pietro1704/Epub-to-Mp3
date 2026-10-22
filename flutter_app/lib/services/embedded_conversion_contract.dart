import 'dart:typed_data';

import '../models/ebook_fulltext.dart';
import 'embedded_conversion_result.dart';
import 'growing_chapter_audio_source.dart';

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
