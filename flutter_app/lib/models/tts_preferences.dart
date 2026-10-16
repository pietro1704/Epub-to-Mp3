import 'dart:convert';

/// Immutable provider selection captured when a conversion starts.
class TtsSelection {
  const TtsSelection({required this.engine, this.modelId, this.voice});
  final String engine;
  final String? modelId;
  final String? voice;
  static const faber = TtsSelection(
    engine: 'piper',
    modelId: 'pt_BR-faber-medium',
  );
  static const edge = TtsSelection(engine: 'edge');
  String get displayName => [
    engine == 'piper'
        ? 'Piper'
        : engine == 'edge'
        ? 'Edge'
        : engine,
    modelId,
    voice,
  ].whereType<String>().join(' · ');
  Map<String, dynamic> toJson() => {
    'engine': engine,
    'model_id': modelId,
    'voice': voice,
  };
  factory TtsSelection.fromJson(Map<String, dynamic> json) => TtsSelection(
    engine: json['engine'] as String,
    modelId: json['model_id'] as String?,
    voice: json['voice'] as String?,
  );
}

class TtsPreferences {
  const TtsPreferences({
    this.primary = TtsSelection.faber,
    this.secondary,
    this.allowOnlineFallback = false,
  });
  final TtsSelection primary;
  final TtsSelection? secondary;
  final bool allowOnlineFallback;
  Map<String, dynamic> toJson() => {
    'primary': primary.toJson(),
    'secondary': secondary?.toJson(),
    'allow_online_fallback': allowOnlineFallback,
  };
  factory TtsPreferences.fromJson(Map<String, dynamic> json) => TtsPreferences(
    primary: TtsSelection.fromJson(
      Map<String, dynamic>.from(json['primary'] as Map),
    ),
    secondary: json['secondary'] == null
        ? null
        : TtsSelection.fromJson(
            Map<String, dynamic>.from(json['secondary'] as Map),
          ),
    allowOnlineFallback: json['allow_online_fallback'] == true,
  );
  String optionsJson({String? modelsRoot, String? language}) => jsonEncode({
    'tts_preferences': toJson(),
    'models_root': ?modelsRoot,
    'language': ?language,
  });
}
