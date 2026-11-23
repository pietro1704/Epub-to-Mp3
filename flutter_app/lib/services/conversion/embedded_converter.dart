import 'model_install/model_install_models.dart';
import 'model_install/model_install_runner.dart' show ModelInstallCancellation;
import '../../models/ebook_fulltext.dart';
import 'embedded_conversion_contract.dart';
import 'embedded_conversion_result.dart';

export 'android_converter_channel.dart';
export 'embedded_conversion_contract.dart';
export 'embedded_conversion_result.dart';

class UnavailableEmbeddedConverter implements EmbeddedConverter {
  const UnavailableEmbeddedConverter();

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
  Stream<ModelInstallEvent> installTtsModelWithProgress({
    required String modelId,
    required String root,
    ModelInstallCancellation? cancellation,
  }) => installWithoutProgress(
    installTtsModelFromCatalog,
    modelId: modelId,
    root: root,
  );

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
