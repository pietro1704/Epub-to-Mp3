import 'dart:async';

import '../../models/ebook_fulltext.dart';
import '../../models/language_model_resolution.dart';
import 'model_install/model_install_models.dart';
import 'model_install/model_install_runner.dart' show ModelInstallCancellation;
import 'embedded_conversion_result.dart';
import '../playback/growing_chapter_audio_source.dart';

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

  /// Base languages with at least one catalog model on this platform.
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages();

  /// Rust's answer to "which narration plays this book language". Pure; never
  /// downloads (`docs/models-by-language-contract.md`).
  Future<LanguageModelResolution> resolveLanguageModel(
    LanguageModelRequest request,
  );

  /// What Rust detects in the book file. Blocking natively; implementations run
  /// it off the UI thread.
  Future<BookLanguageAnalysis> bookLanguage(String path);
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

  /// Installs a catalog model and reports its progress. Runtimes without the
  /// shared install-operation binding use [installWithoutProgress].
  Stream<ModelInstallEvent> installTtsModelWithProgress({
    required String modelId,
    required String root,
    ModelInstallCancellation? cancellation,
  });
}

abstract interface class CancellableEmbeddedConverter {
  Future<void> cancelConversion({String? inputPath, String? outputPath});
}

/// Offline catalog and readiness operations for an explicit model choice.
abstract interface class ManualTtsModelCatalog {
  Future<String> ttsManualModels({required String root});
  Future<String> probeTtsModel({
    required String modelId,
    required String root,
    String? language,
  });
}

/// Process-wide limit on the CPU share local synthesis may use while the app is
/// in the background (percent of one core); 0 lifts it. Rust owns the pacing.
abstract interface class BackgroundPacingCapable {
  Future<void> setBackgroundCpuLimit(int percent);
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

/// Native source slicing stays in Rust; offsets count Unicode scalars.
abstract interface class PositionedChapterConverter {
  Future<ConvertedChapterAudio> convertPositionedChapter({
    required String inputPath, required String outputPath, required int chapterIndex,
    required int textOffset, String? optionsJson,
    Future<void> Function(GrowingChapterAudioSource)? onFirstAudio,
  });
}

/// Fallback for runtimes that only have the blocking installer: it reports a
/// start and an end, with no byte progress.
Stream<ModelInstallEvent> installWithoutProgress(
  Future<String> Function({required String modelId, required String root}) install, {
  required String modelId,
  required String root,
}) async* {
  ModelInstallEvent event(ModelInstallStage stage, {ModelInstallFailure? failure}) =>
      ModelInstallEvent(
        sequence: 0,
        modelId: modelId,
        stage: stage,
        bytesCompleted: 0,
        bytesTotal: 0,
        failure: failure,
      );
  yield event(ModelInstallStage.downloading);
  try {
    await install(modelId: modelId, root: root);
    yield event(ModelInstallStage.completed);
  } on Object catch (error) {
    yield event(
      ModelInstallStage.failed,
      failure: ModelInstallFailure(kind: 'install_failed', message: error.toString()),
    );
  }
}
