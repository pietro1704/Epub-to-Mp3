import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/android_speech_fallback.dart';

class _FakeSpeechAdapter implements SpeechPlatformAdapter {
  _FakeSpeechAdapter({this.available = true, this.locales = const ['en-US']});

  final bool available;
  final List<String> locales;
  final calls = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<SpeechVoice>> listVoices() async => locales
      .map((locale) => SpeechVoice(name: 'voice-$locale', locale: locale))
      .toList();

  @override
  Future<void> speak(String text, {required String locale}) async {
    calls.add('speak:$locale:$text');
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  group('AndroidSpeechFallback', () {
    test('uses offline engine only after primary audio is unavailable', () {
      expect(
        selectPlaybackEngine(hasAudio: true, offlineAvailable: true),
        PlaybackEngine.primaryAudio,
      );
      expect(
        selectPlaybackEngine(hasAudio: false, offlineAvailable: true),
        PlaybackEngine.offlineSpeech,
      );
      expect(
        selectPlaybackEngine(hasAudio: false, offlineAvailable: false),
        PlaybackEngine.unavailable,
      );
    });

    test('lists voices and preserves requested locale', () async {
      final adapter = _FakeSpeechAdapter(locales: const ['pt-BR', 'en-US']);
      final engine = AndroidSpeechFallback(adapter: adapter);

      expect(await engine.isAvailable(), isTrue);
      expect((await engine.listVoices()).map((v) => v.locale), [
        'pt-BR',
        'en-US',
      ]);

      await engine.speak('Olá', locale: 'pt-BR');
      expect(adapter.calls, ['speak:pt-BR:Olá']);
    });

    test('forwards pause and stop to the platform adapter', () async {
      final adapter = _FakeSpeechAdapter();
      final engine = AndroidSpeechFallback(adapter: adapter);

      await engine.pause();
      await engine.stop();

      expect(adapter.calls, ['pause', 'stop']);
    });

    test('is a no-op when the Android TTS engine is unavailable', () async {
      final adapter = _FakeSpeechAdapter(available: false);
      final engine = AndroidSpeechFallback(adapter: adapter);

      await engine.speak('ignored', locale: 'en-US');
      await engine.pause();
      await engine.stop();

      expect(adapter.calls, isEmpty);
    });
  });
}
