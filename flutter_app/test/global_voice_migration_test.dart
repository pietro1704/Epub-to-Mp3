import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/playback/global_voice_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The global primary/reserve menus leave the Models screen: what the user had chosen there
/// becomes a per-language choice once, so nothing they selected is lost.
Map<String, dynamic> _model(String id, List<String> tags, {String engine = 'piper'}) => {
  'id': id,
  'engine': engine,
  'languages': tags,
};

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  final models = [
    _model('pt_BR-faber-medium', ['pt-BR']),
    _model('en_US-lessac-medium', ['en-US']),
    _model('edge-pt', ['pt-BR'], engine: 'edge'),
  ];

  test('a specific Piper primary becomes the choice of its language and the primary is automatic again', () async {
    final choices = <String, TtsSelection>{};
    TtsPreferences? saved;
    await migrateGlobalVoiceToLanguageChoices(
      prefs: prefs,
      configured: const TtsPreferences(
        primary: TtsSelection(engine: 'piper', modelId: 'en_US-lessac-medium'),
        secondary: TtsSelection.system,
        policyVersion: 2,
      ),
      models: models,
      choiceFor: (language) => choices[language],
      choose: (language, selection) => choices[language] = selection,
      savePreferences: (preferences) async => saved = preferences,
    );
    expect(choices['en']?.modelId, 'en_US-lessac-medium');
    expect(saved?.primary.representsSameRequest(TtsSelection.automaticPiper), isTrue);
    expect(saved?.secondary?.engine, 'system', reason: 'the reserve voice is untouched');
  });

  test('an existing choice for the language wins over the old global voice', () async {
    final choices = <String, TtsSelection>{
      'pt': const TtsSelection(engine: 'piper', modelId: 'pt_BR-cadu-medium'),
    };
    await migrateGlobalVoiceToLanguageChoices(
      prefs: prefs,
      configured: const TtsPreferences(primary: TtsSelection.faber, secondary: TtsSelection.system),
      models: models,
      choiceFor: (language) => choices[language],
      choose: (language, selection) => choices[language] = selection,
      savePreferences: (_) async {},
    );
    expect(choices['pt']?.modelId, 'pt_BR-cadu-medium');
  });

  test('it runs once, and an automatic or Edge primary is left alone', () async {
    final choices = <String, TtsSelection>{};
    var saves = 0;
    Future<void> run(TtsPreferences configured) => migrateGlobalVoiceToLanguageChoices(
      prefs: prefs,
      configured: configured,
      models: models,
      choiceFor: (language) => choices[language],
      choose: (language, selection) => choices[language] = selection,
      savePreferences: (_) async => saves++,
    );
    await run(const TtsPreferences.appDefaults());
    expect(choices, isEmpty);
    expect(saves, 0);
    // Already migrated: a later specific primary is not touched again.
    await run(const TtsPreferences(primary: TtsSelection.faber, secondary: TtsSelection.system));
    expect(choices, isEmpty, reason: 'once only');
    expect(prefs.getBool(globalVoiceMigratedKey), isTrue);
  });

  test('an Edge primary stays as it is: it has no language to move to', () async {
    final choices = <String, TtsSelection>{};
    var saves = 0;
    await migrateGlobalVoiceToLanguageChoices(
      prefs: prefs,
      configured: const TtsPreferences(
        primary: TtsSelection.edge,
        secondary: TtsSelection.system,
        allowOnlineFallback: true,
      ),
      models: models,
      choiceFor: (language) => choices[language],
      choose: (language, selection) => choices[language] = selection,
      savePreferences: (_) async => saves++,
    );
    expect(choices, isEmpty);
    expect(saves, 0);
  });
}
