import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('base language folds regional tags and case', () {
    expect(LanguageModelChoices.baseLanguage('pt-BR'), 'pt');
    expect(LanguageModelChoices.baseLanguage('pt_BR'), 'pt');
    expect(LanguageModelChoices.baseLanguage(' EN '), 'en');
    expect(LanguageModelChoices.baseLanguage(''), '');
  });

  test('a choice applies to every region of its language and clears to automatic', () {
    final choices = LanguageModelChoices.empty.withChoice('pt-BR', TtsSelection.faber);
    expect(choices.choiceFor('pt-PT')?.modelId, 'pt_BR-faber-medium');
    expect(choices.choiceFor('en'), isNull);
    final cleared = choices.without('pt');
    expect(cleared.byLanguage, isEmpty);
    expect(identical(cleared.without('pt'), cleared), isTrue, reason: 'nothing to clear');
    expect(identical(LanguageModelChoices.empty.withChoice('', TtsSelection.faber), LanguageModelChoices.empty), isTrue);
  });

  test('encode and parse round-trip the shared JSON object', () {
    final choices = const LanguageModelChoices().withChoice('pt', TtsSelection.faber).withChoice('en', TtsSelection.edge);
    final restored = LanguageModelChoices.parse(choices.encode());
    expect(restored.byLanguage.keys.toSet(), {'pt', 'en'});
    expect(restored.choiceFor('pt')?.modelId, 'pt_BR-faber-medium');
    expect(restored.choiceFor('en')?.engine, 'edge');
  });

  test('parsing tolerates corrupt data and keeps valid neighbours', () {
    expect(LanguageModelChoices.parse(null).byLanguage, isEmpty);
    expect(LanguageModelChoices.parse('').byLanguage, isEmpty);
    expect(LanguageModelChoices.parse('not json').byLanguage, isEmpty);
    expect(LanguageModelChoices.parse('[1,2]').byLanguage, isEmpty);
    final partial = LanguageModelChoices.parse(
      '{"pt":{"engine":"piper","model_id":"pt_BR-faber-medium"},"en":"oops","de":{"model_id":"missing-engine"},"PT-br":{"engine":"system"}}',
    );
    expect(partial.byLanguage.keys, ['pt'], reason: 'invalid entries skipped; a later duplicate key replaces');
    expect(partial.choiceFor('pt')?.engine, 'system');
  });

  test('the provider persists choices across a relaunch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
    addTearDown(() => container.dispose());
    container.read(languageModelChoicesProvider.notifier).choose('pt-BR', TtsSelection.faber);
    container.read(languageModelChoicesProvider.notifier).choose('en', TtsSelection.system);
    expect(prefs.getString('languageModelChoices.v1'), isNotNull);

    container.dispose();
    container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
    final restored = container.read(languageModelChoicesProvider);
    expect(restored.choiceFor('pt')?.modelId, 'pt_BR-faber-medium');
    expect(restored.choiceFor('en')?.engine, 'system');

    container.read(languageModelChoicesProvider.notifier).clear('pt');
    expect(LanguageModelChoices.parse(prefs.getString('languageModelChoices.v1')).byLanguage.keys, ['en']);
  });
}
