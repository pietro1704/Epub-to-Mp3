/// Captured runtime identity; decoded by Rust before preparing a session.
class TtsSessionSelection {
  TtsSessionSelection({required this.provider, required this.runtime, this.modelId,
    this.modelRevision, this.voice, Map<String, String> options = const {}})
    : options = Map.unmodifiable(options);
  final String provider;
  final String runtime;
  final String? modelId;
  final String? modelRevision;
  final String? voice;
  final Map<String, String> options;
  Map<String, dynamic> toJson() => {
    'version': 2, 'provider': provider, 'runtime': runtime, 'model_id': modelId,
    'model_revision': modelRevision, 'voice': voice, 'options': options,
  };
  factory TtsSessionSelection.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 2) { throw const FormatException('Unsupported TTS session version'); }
    return TtsSessionSelection(provider: json['provider'] as String, runtime: json['runtime'] as String,
      modelId: json['model_id'] as String?, modelRevision: json['model_revision'] as String?,
      voice: json['voice'] as String?, options: Map<String, String>.from(json['options'] as Map? ?? const {}));
  }
}
