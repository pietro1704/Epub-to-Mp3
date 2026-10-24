import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'tts_preferences.dart';
import 'tts_session_selection.dart';

class TtsCatalog {
  TtsCatalog._(this.models, this.providers, this.androidApi);
  final List<Map<String, dynamic>> models;
  final List<Map<String, dynamic>> providers;
  final int? androidApi;
  factory TtsCatalog.decode(String json) {
    final decoded = jsonDecode(json);
    // Older embedded libraries retain their read-only model listing.
    final Object? entries;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map && decoded['version'] == 2) {
      entries = decoded['models'];
    } else {
      throw const FormatException('Unsupported TTS catalog version');
    }
    if (entries is! List) { throw const FormatException('Invalid TTS model catalog'); }
    final providers = decoded is Map && decoded['providers'] is List ? decoded['providers'] as List : const [];
    return TtsCatalog._(List.unmodifiable(entries.map((value) => Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(value as Map)))),
      List.unmodifiable(providers.map((value) => Map<String, dynamic>.from(value as Map))), decoded is Map ? decoded['android_api'] as int? : null);
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
