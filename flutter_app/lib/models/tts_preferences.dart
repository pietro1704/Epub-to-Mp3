import 'dart:convert';
import 'tts_session_selection.dart';

/// Immutable provider selection captured when a conversion starts.
class TtsSelection {
  const TtsSelection({required this.engine, this.modelId, this.voice, this.session});
  final String engine;
  final String? modelId;
  final String? voice;
  final TtsSessionSelection? session;
  bool representsSameRequest(TtsSelection other) {
    if (engine != other.engine || modelId != other.modelId || voice != other.voice) { return false; }
    final first = session;
    final second = other.session;
    if (first != null && second != null && first.runtime != second.runtime) { return false; }
    final options = first?.options ?? const <String, String>{};
    final otherOptions = second?.options ?? const <String, String>{};
    return options.length == otherOptions.length && options.entries.every((entry) => otherOptions[entry.key] == entry.value);
  }
  static const faber = TtsSelection(
    engine: 'piper',
    modelId: 'pt_BR-faber-medium',
  );
  static const edge = TtsSelection(engine: 'edge');
  static const system = TtsSelection(engine: 'system');
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
    if (session != null) 'session': session!.toJson(),
  };
  factory TtsSelection.fromJson(Map<String, dynamic> json) => TtsSelection(
    engine: json['engine'] as String,
    modelId: json['model_id'] as String?,
    voice: json['voice'] as String?,
    session: json['session'] == null ? null : TtsSessionSelection.fromJson(Map<String, dynamic>.from(json['session'] as Map)),
  );
}

class TtsPreferences {
  TtsPreferences withPrimary(TtsSelection selection) => TtsPreferences(
    primary: selection,
    secondary: secondary?.representsSameRequest(selection) == true ? null : secondary,
    allowOnlineFallback: allowOnlineFallback,
    policyVersion: policyVersion,
  );
  const TtsPreferences({
    this.primary = TtsSelection.faber,
    this.secondary,
    this.allowOnlineFallback = false,
    this.policyVersion = 1,
  });
  /// New app preferences only; legacy jobs retain their captured strict policy.
  const TtsPreferences.appDefaults()
    : primary = TtsSelection.faber,
      secondary = TtsSelection.system,
      allowOnlineFallback = false,
      policyVersion = 2;
  final TtsSelection primary;
  final TtsSelection? secondary;
  final bool allowOnlineFallback;
  final int policyVersion;
  Map<String, dynamic> toJson() => {
    'primary': primary.toJson(),
    'secondary': secondary?.toJson(),
    'allow_online_fallback': allowOnlineFallback,
    if (policyVersion != 1) 'policy_version': policyVersion,
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
    policyVersion: json['policy_version'] as int? ?? 1,
  );
  String optionsJson({String? modelsRoot, String? language}) => jsonEncode({
    if (primary.session != null || secondary?.session != null) 'contract_version': 2,
    'tts_preferences': toJson(),
    'models_root': ?modelsRoot,
    'language': ?language,
  });
}
