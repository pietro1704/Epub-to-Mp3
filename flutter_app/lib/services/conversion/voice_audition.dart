import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/tts_preferences.dart';

/// An online (Edge) sample was asked for while online voices are not allowed.
class OnlineVoiceConsentRequired implements Exception {
  const OnlineVoiceConsentRequired();
}

/// Lets the platform renderer stop a sample that is still being synthesized.
class AuditionCancellation {
  bool _cancelled = false;
  VoidCallback? onCancel;
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    onCancel?.call();
  }
}

enum VoiceAuditionState { idle, generating, playing, failed }

typedef AuditionRender = Future<void> Function(
  String optionsJson,
  String text,
  String output,
  AuditionCancellation cancel,
);

/// One short voice sample: it renders to a temporary MP3 through the converter and plays it.
/// It never changes the user's settings, library or playback session.
class VoiceAudition {
  VoiceAudition({
    required this.render,
    required this.play,
    required this.stopPlayback,
  });

  final AuditionRender render;
  final Future<void> Function(String path) play;
  final Future<void> Function() stopPlayback;
  final ValueNotifier<VoiceAuditionState> state = ValueNotifier(
    VoiceAuditionState.idle,
  );

  Directory? _directory;
  AuditionCancellation? _cancel;
  int _generation = 0;

  static String sampleText(String language) => switch (language
      .substring(0, language.length < 2 ? language.length : 2)
      .toLowerCase()) {
    'pt' => 'Esta é uma amostra da voz para narrar seus livros. Boa leitura!',
    'es' =>
      'Esta es una muestra de la voz para narrar tus libros. ¡Buena lectura!',
    _ => 'This is a sample of the voice for narrating your books. Enjoy your reading!',
  };

  /// Version-2 options for one voice, no fallback; Edge needs the online consent.
  static String optionsJson(
    TtsSelection selection,
    String language, {
    required bool allowOnline,
    required String? modelsRoot,
  }) {
    if (selection.engine == 'edge' && !allowOnline) {
      throw const OnlineVoiceConsentRequired();
    }
    return TtsPreferences(
      primary: selection,
      allowOnlineFallback: selection.engine == 'edge',
    ).optionsJson(modelsRoot: modelsRoot, language: language);
  }

  Future<void> start(
    TtsSelection selection,
    String language, {
    required bool allowOnline,
    required String? modelsRoot,
  }) async {
    await stop();
    final options = optionsJson(
      selection,
      language,
      allowOnline: allowOnline,
      modelsRoot: modelsRoot,
    );
    final attempt = ++_generation;
    final cancel = _cancel = AuditionCancellation();
    state.value = VoiceAuditionState.generating;
    final directory = _directory = Directory.systemTemp.createTempSync(
      'voice-audition',
    );
    final output = '${directory.path}/preview.mp3';
    try {
      await render(options, sampleText(language), output, cancel);
      if (attempt != _generation || cancel.isCancelled) {
        _cleanup(directory);
        return;
      }
      await play(output);
      if (attempt != _generation) return;
      state.value = VoiceAuditionState.playing;
    } on Object {
      _cleanup(directory);
      if (attempt == _generation) state.value = VoiceAuditionState.failed;
      rethrow;
    }
  }

  Future<void> stop() async {
    _generation++;
    _cancel?.cancel();
    _cancel = null;
    await stopPlayback();
    final directory = _directory;
    if (directory != null) _cleanup(directory);
    state.value = VoiceAuditionState.idle;
  }

  void _cleanup(Directory directory) {
    try {
      directory.deleteSync(recursive: true);
    } on Object {
      // best effort
    }
    if (identical(_directory, directory)) _directory = null;
  }
}
