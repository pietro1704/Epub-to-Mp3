import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/tts_model_catalog.dart';

void main() {
  test('does not select a local engine before a model is installed', () {
    expect(
      TtsModelCatalog.defaultEngine(language: 'en-US', platform: 'macos'),
      'none',
    );
  });

  test('keeps Android API 28 without an implicit local engine', () {
    expect(
      TtsModelCatalog.defaultEngine(
        language: 'pt-BR',
        platform: 'android',
        androidApi: 28,
      ),
      'none',
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
