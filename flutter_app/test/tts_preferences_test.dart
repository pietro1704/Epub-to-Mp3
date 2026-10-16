import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/tts_preferences.dart';

void main() {
  test('fresh settings choose Faber without online consent', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    expect(settings.ttsPreferences.primary.modelId, 'pt_BR-faber-medium');
    expect(settings.ttsPreferences.secondary, isNull);
    expect(settings.ttsPreferences.allowOnlineFallback, false);
  });
  test('explicit legacy Edge choice survives migration', () async {
    SharedPreferences.setMockInitialValues({
      'audioEngine': 'edge',
      'voice': 'pt-BR-AntonioNeural',
    });
    final settings = MirrorAppSettings(await SharedPreferences.getInstance());
    expect(settings.ttsPreferences.primary.engine, 'edge');
    expect(settings.ttsPreferences.primary.voice, 'pt-BR-AntonioNeural');
  });
  test('immutable captured options survive preference edits', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = MirrorAppSettings(prefs);
    final captured = settings.ttsPreferences.optionsJson(modelsRoot: '/models');
    await settings.setTtsPreferences(
      const TtsPreferences(primary: TtsSelection.edge),
    );
    final options = jsonDecode(captured) as Map<String, dynamic>;
    expect(options['models_root'], '/models');
    expect(
      options['tts_preferences']['primary']['model_id'],
      'pt_BR-faber-medium',
    );
    expect(MirrorAppSettings(prefs).ttsPreferences.primary.engine, 'edge');
  });
  test('secondary and online consent persist independently', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await MirrorAppSettings(prefs).setTtsPreferences(
      const TtsPreferences(
        secondary: TtsSelection(engine: 'edge', voice: 'pt-BR-FranciscaNeural'),
        allowOnlineFallback: true,
      ),
    );
    final saved = MirrorAppSettings(prefs).ttsPreferences;
    expect(saved.secondary!.voice, 'pt-BR-FranciscaNeural');
    expect(saved.allowOnlineFallback, true);
  });
}
