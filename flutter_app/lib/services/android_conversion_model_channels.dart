part of 'android_converter_channel.dart';

mixin _AndroidConversionModelChannels implements EmbeddedConverter {
  MethodChannel get _channel;

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
