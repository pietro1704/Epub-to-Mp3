import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// A voice exposed by the platform's installed offline speech engine.
class SpeechVoice {
  const SpeechVoice({required this.name, required this.locale});

  final String name;
  final String locale;
}

/// Transport-independent speech contract. Implementations must be safe to
/// construct and call on host platforms where Android is not available.
abstract interface class SpeechEngine {
  Future<void> speak(String text, {required String locale});
  Future<void> pause();
  Future<void> stop();
  Future<bool> isAvailable();
  Future<List<SpeechVoice>> listVoices();
}

/// The small platform surface needed by [AndroidSpeechFallback]. Keeping it
/// injectable makes all fallback policy testable without Android bindings.
abstract interface class SpeechPlatformAdapter {
  Future<void> speak(String text, {required String locale});
  Future<void> pause();
  Future<void> stop();
  Future<bool> isAvailable();
  Future<List<SpeechVoice>> listVoices();
}

enum PlaybackEngine { primaryAudio, offlineSpeech, unavailable }

/// Edge/cloud or generated audio always wins. Offline speech is an explicit
/// fallback only when no playable audio exists.
PlaybackEngine selectPlaybackEngine({
  required bool hasAudio,
  required bool offlineAvailable,
}) {
  if (hasAudio) return PlaybackEngine.primaryAudio;
  if (offlineAvailable) return PlaybackEngine.offlineSpeech;
  return PlaybackEngine.unavailable;
}

class AndroidSpeechFallback implements SpeechEngine {
  AndroidSpeechFallback({SpeechPlatformAdapter? adapter})
    : _adapter = adapter ?? const _DefaultSpeechPlatformAdapter();

  final SpeechPlatformAdapter _adapter;

  @override
  Future<bool> isAvailable() => _adapter.isAvailable();

  @override
  Future<List<SpeechVoice>> listVoices() async {
    if (!await isAvailable()) return const [];
    return _adapter.listVoices();
  }

  @override
  Future<void> speak(String text, {required String locale}) async {
    if (text.trim().isEmpty || !await isAvailable()) return;
    await _adapter.speak(text, locale: locale);
  }

  @override
  Future<void> pause() async {
    if (await isAvailable()) await _adapter.pause();
  }

  @override
  Future<void> stop() async {
    if (await isAvailable()) await _adapter.stop();
  }
}

class _DefaultSpeechPlatformAdapter implements SpeechPlatformAdapter {
  const _DefaultSpeechPlatformAdapter();

  static const _channel = MethodChannel('epub_to_mp3/android_tts');

  @override
  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<SpeechVoice>> listVoices() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listVoices');
      return (raw ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (entry) => SpeechVoice(
              name: entry['name']?.toString() ?? '',
              locale: entry['locale']?.toString() ?? '',
            ),
          )
          .where((voice) => voice.locale.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> speak(String text, {required String locale}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('speak', {
        'text': text,
        'locale': locale,
      });
    } on MissingPluginException {
      // Host tests and desktop builds intentionally no-op.
    } on PlatformException {
      // A missing/disabled TTS package is a normal fallback miss.
    }
  }

  @override
  Future<void> pause() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('pause');
    } on MissingPluginException {
      // Host tests and desktop builds intentionally no-op.
    } on PlatformException {
      // A missing/disabled TTS package is a normal fallback miss.
    }
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Host tests and desktop builds intentionally no-op.
    } on PlatformException {
      // A missing/disabled TTS package is a normal fallback miss.
    }
  }
}
