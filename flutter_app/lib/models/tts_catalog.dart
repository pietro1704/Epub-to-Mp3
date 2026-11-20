import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'tts_preferences.dart';
import 'tts_session_selection.dart';

class TtsCatalog {
  TtsCatalog._(
    this.models,
    this.providers,
    this.androidApi,
    this.defaultSelection,
  );
  final List<Map<String, dynamic>> models;
  final List<Map<String, dynamic>> providers;
  final int? androidApi;
  final TtsSelection? defaultSelection;

  TtsPreferences get recommendedPreferences => const TtsPreferences.appDefaults();
  factory TtsCatalog.decode(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['schema_version'] != 3) {
      throw const FormatException('Unsupported TTS catalog version');
    }
    final entries = decoded['entries'];
    final providers = decoded['providers'];
    if (entries is! List || providers is! List) {
      throw const FormatException('Invalid TTS model catalog');
    }
    final models = entries.map((entry) {
      final identity = entry['identity'] as Map;
      final compatibility = entry['compatibility'] as Map;
      final distribution = entry['distribution'] as Map;
      return Map<String, dynamic>.unmodifiable({
        'id': identity['model_id'], 'engine': identity['provider'],
        'runtime': identity['runtime'], 'revision': identity['model_revision'],
        'languages': entry['language_evidence']['routing_tags'],
        'platforms': compatibility['platforms'],
        'minimum_android_api': compatibility['minimum_android_api'],
        'runtime_available': compatibility['runtime_available'],
        'artifacts': distribution['artifacts'],
        'download_bytes': distribution['download_bytes'],
      });
    });
    final target = decoded['target'];
    final defaultValue = decoded['default_selection'];
    final session = defaultValue == null
        ? null
        : TtsSessionSelection.fromJson(
            Map<String, dynamic>.from(defaultValue as Map),
          );
    return TtsCatalog._(
      List.unmodifiable(models),
      List.unmodifiable(providers.map((value) => Map<String, dynamic>.from(value as Map))),
      decoded['android_api'] as int? ?? (target is Map ? target['android_api'] as int? : null),
      session == null
          ? null
          : TtsSelection(
              engine: session.provider,
              modelId: session.modelId,
              voice: session.voice,
              session: session,
            ),
    );
  }
  /// Capture new jobs only. Persisted requests keep their original wire identity.
  TtsPreferences captureNewPreferences(TtsPreferences preferences, {String? target}) {
    final choices = selections(target: target);
    TtsSelection capture(TtsSelection selected) {
      if (selected.session != null || selected.modelId == null) return selected;
      final matches = choices.where((choice) => choice.engine == selected.engine && choice.modelId == selected.modelId);
      if (matches.isEmpty) return selected;
      final resolved = matches.first.session!;
      return TtsSelection(engine: selected.engine, modelId: selected.modelId, voice: selected.voice,
        session: TtsSessionSelection(provider: resolved.provider, runtime: resolved.runtime,
          modelId: resolved.modelId, modelRevision: resolved.modelRevision, voice: selected.voice,
          options: resolved.options));
    }
    return TtsPreferences(primary: capture(preferences.primary),
      secondary: preferences.secondary == null ? null : capture(preferences.secondary!),
      allowOnlineFallback: preferences.allowOnlineFallback, policyVersion: preferences.policyVersion);
  }
  List<TtsSelection> selections({String? target, int? androidApi}) {
    final platform = target ?? switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android', TargetPlatform.iOS => 'Ios',
      TargetPlatform.macOS => 'Macos', TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux', TargetPlatform.fuchsia => 'Fuchsia',
    };
    return [
    for (final model in models)
      if (model['runtime'] is String && model['runtime_available'] == true)
        if (model['platforms'] is! List || (model['platforms'] as List).contains(platform))
          if (platform != 'Android' || model['minimum_android_api'] == null || (model['minimum_android_api'] as int) <= (androidApi ?? this.androidApi ?? 21))
            if (providers.any((provider) => provider['provider'] == model['engine'] && provider['runtime'] == model['runtime'] &&
              (provider['targets'] as List?)?.contains(platform.toLowerCase()) == true &&
              (provider['capabilities'] as Map?)?['audio_bytes'] == true))
        TtsSelection(engine: model['engine'] as String, modelId: model['id'] as String,
          session: TtsSessionSelection(provider: model['engine'] as String, runtime: model['runtime'] as String,
            modelId: model['id'] as String, modelRevision: model['revision'] as String?)),
  ]; }
}
