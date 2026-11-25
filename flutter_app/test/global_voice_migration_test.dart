import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/playback/global_voice_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The global primary/reserve menus leave the Models screen: what the user had chosen there
/// becomes a per-language choice once, so nothing they selected is lost.
Map<String, dynamic> _model(
  String id,
  List<String> tags, {
  String engine = 'piper',
}) => {'id': id, 'engine': engine, 'languages': tags};

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
    expect(
      saved?.primary.representsSameRequest(TtsSelection.automaticPiper),
      isTrue,
    );
    expect(
      saved?.secondary?.engine,
      'system',
      reason: 'the reserve voice is untouched',
    );
  });

  test(
    'an existing choice for the language wins over the old global voice',
    () async {
      final choices = <String, TtsSelection>{
        'pt': const TtsSelection(engine: 'piper', modelId: 'pt_BR-cadu-medium'),
      };
      await migrateGlobalVoiceToLanguageChoices(
        prefs: prefs,
        configured: const TtsPreferences(
          primary: TtsSelection.faber,
          secondary: TtsSelection.system,
        ),
        models: models,
        choiceFor: (language) => choices[language],
        choose: (language, selection) => choices[language] = selection,
        savePreferences: (_) async {},
      );
      expect(choices['pt']?.modelId, 'pt_BR-cadu-medium');
    },
  );

  test(
    'it runs once, and an automatic or Edge primary is left alone',
    () async {
      final choices = <String, TtsSelection>{};
      var saves = 0;
      Future<void> run(TtsPreferences configured) =>
          migrateGlobalVoiceToLanguageChoices(
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
      await run(
        const TtsPreferences(
          primary: TtsSelection.faber,
          secondary: TtsSelection.system,
        ),
      );
      expect(choices, isEmpty, reason: 'once only');
      expect(prefs.getBool(globalVoiceMigratedKey), isTrue);
    },
  );

  Future<TtsPreferences?> run(
    TtsPreferences configured,
    Map<String, TtsSelection> choices, {
    List<String> device = const ['pt', 'en'],
    List<String> library = const [],
  }) async {
    TtsPreferences? saved;
    await migrateGlobalVoiceToLanguageChoices(
      prefs: prefs,
      configured: configured,
      models: models,
      choiceFor: (language) => choices[language],
      choose: (language, selection) => choices[language] = selection,
      savePreferences: (preferences) async => saved = preferences,
      deviceLanguages: device,
      libraryLanguages: library,
    );
    return saved;
  }

  test(
    'a system primary becomes the choice of the device and library languages',
    () async {
      final choices = <String, TtsSelection>{
        'en': const TtsSelection(
          engine: 'piper',
          modelId: 'en_US-lessac-medium',
        ),
      };
      final saved = await run(
        const TtsPreferences(primary: TtsSelection.system, policyVersion: 2),
        choices,
        library: const ['es', 'en'],
      );
      expect(choices['pt']?.engine, 'system');
      expect(choices['es']?.engine, 'system');
      expect(
        choices['en']?.modelId,
        'en_US-lessac-medium',
        reason: 'an existing choice wins',
      );
      expect(
        saved?.primary.representsSameRequest(TtsSelection.automaticPiper),
        isTrue,
      );
    },
  );

  test(
    'a consented Edge primary becomes the choice of those languages',
    () async {
      final choices = <String, TtsSelection>{};
      final saved = await run(
        const TtsPreferences(
          primary: TtsSelection.edge,
          allowOnlineFallback: true,
        ),
        choices,
      );
      expect(choices.keys.toSet(), {'pt', 'en'});
      expect(choices['pt']?.engine, 'edge');
      expect(
        saved?.primary.representsSameRequest(TtsSelection.automaticPiper),
        isTrue,
      );
    },
  );

  test('an Edge primary without consent is never copied', () async {
    final choices = <String, TtsSelection>{};
    final saved = await run(
      const TtsPreferences(primary: TtsSelection.edge),
      choices,
    );
    expect(choices, isEmpty);
    expect(
      saved?.primary.representsSameRequest(TtsSelection.automaticPiper),
      isTrue,
    );
  });

  test(
    'a reserve equal to the new primary swaps with the old primary',
    () async {
      final saved = await run(
        const TtsPreferences(
          primary: TtsSelection.system,
          secondary: TtsSelection.automaticPiper,
        ),
        <String, TtsSelection>{},
      );
      expect(
        saved?.primary.representsSameRequest(TtsSelection.automaticPiper),
        isTrue,
      );
      expect(saved?.secondary?.engine, 'system');
    },
  );

  test('a reserve different from the new primary is kept', () async {
    final saved = await run(
      const TtsPreferences(
        primary: TtsSelection.system,
        secondary: TtsSelection.faber,
      ),
      <String, TtsSelection>{},
    );
    expect(saved?.secondary?.modelId, TtsSelection.faber.modelId);
  });

  test('a user who already ran the first migration still gets the system primary moved', () async {
    SharedPreferences.setMockInitialValues({
      'voice.globalMenusMigrated.v1': true,
    });
    prefs = await SharedPreferences.getInstance();
    final choices = <String, TtsSelection>{};
    await run(const TtsPreferences(primary: TtsSelection.system), choices);
    expect(choices['pt']?.engine, 'system');
    final again = <String, TtsSelection>{};
    await run(const TtsPreferences(primary: TtsSelection.system), again);
    expect(again, isEmpty, reason: 'the new key makes it run once');
  });
}
