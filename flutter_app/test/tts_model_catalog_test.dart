import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/tts_model_catalog.dart';

void main() {
  test('does not select Kokoro before its runtime is available', () {
    expect(
      TtsModelCatalog.defaultEngine(language: 'en-US', platform: 'macos'),
      'piper',
    );
  });

  test('uses Piper fallback when Kokoro is unavailable on old Android', () {
    expect(
      TtsModelCatalog.defaultEngine(
        language: 'pt-BR',
        platform: 'android',
        androidApi: 28,
      ),
      'piper',
    );
  });

  test('does not offer desktop-only models on mobile', () {
    final models = TtsModelCatalog.candidates(
      language: 'en',
      platform: 'android',
      androidApi: 33,
    );
    expect(models.map((model) => model.engine), isNot(contains('qwen3')));
    expect(models.map((model) => model.engine), isNot(contains('melotts')));
  });

  test(
    'requires language compatibility instead of silently using wrong voice',
    () {
      expect(
        TtsModelCatalog.candidates(language: 'ar', platform: 'macos'),
        isEmpty,
      );
    },
  );
}
