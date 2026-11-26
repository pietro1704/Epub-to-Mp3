/// The voice the Rust core reports for a running conversion, read from the
/// `conversion.log` it appends to the job directory.
class ActiveVoice {
  const ActiveVoice({required this.engine, this.modelId, this.voice});
  final String engine;
  final String? modelId;
  final String? voice;

  bool get isSystem => engine == 'system';

  String get name {
    if (isSystem) return voice ?? modelId ?? engine;
    final label = engine == 'piper'
        ? 'Piper'
        : engine == 'edge'
        ? 'Edge'
        : engine;
    return [label, modelId, voice].whereType<String>().join(' · ');
  }
}

/// Last progress line that named an engine; later lines without one keep it.
ActiveVoice? activeVoiceFromLog(String log) {
  final engine = RegExp(r'engine=Some\("([^"]*)"\)');
  final model = RegExp(r'model_id="([^"]*)"');
  final voice = RegExp(r'voice="([^"]*)"');
  for (final line in log.split('\n').reversed) {
    final match = engine.firstMatch(line);
    if (match == null) continue;
    String? named(RegExp pattern) {
      final value = pattern.firstMatch(line)?.group(1);
      return value == null || value.isEmpty ? null : value;
    }

    return ActiveVoice(
      engine: match.group(1)!,
      modelId: named(model),
      voice: named(voice),
    );
  }
  return null;
}
