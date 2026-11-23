import 'dart:convert';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs(TtsPreferences? saved) async {
  SharedPreferences.setMockInitialValues({
    if (saved != null) 'ttsPreferences': jsonEncode(saved.toJson()),
  });
  return SharedPreferences.getInstance();
}

void main() {
  test('Edge as primary without the online consent migrates to the default Piper', () async {
    final prefs = await _prefs(
      const TtsPreferences(primary: TtsSelection.edge, secondary: TtsSelection.system, policyVersion: 2),
    );
    final settings = MirrorAppSettings(prefs);
    expect(settings.ttsPreferences.primary.representsSameRequest(TtsSelection.automaticPiper), isTrue);
    expect(settings.ttsPreferences.secondary?.engine, 'system', reason: 'the rest of the choice is kept');
    expect(settings.ttsPreferences.policyVersion, 2);
    // Persisted: the migration is not repeated on every launch.
    final stored = TtsPreferences.fromJson(jsonDecode(prefs.getString('ttsPreferences')!) as Map<String, dynamic>);
    expect(stored.primary.engine, 'piper');
  });

  test('Edge as primary WITH the consent is left alone', () async {
    final prefs = await _prefs(
      const TtsPreferences(primary: TtsSelection.edge, allowOnlineFallback: true, policyVersion: 2),
    );
    expect(MirrorAppSettings(prefs).ttsPreferences.primary.engine, 'edge');
  });

  test('revoking the consent migrates an Edge primary at the next load', () async {
    final prefs = await _prefs(
      const TtsPreferences(primary: TtsSelection.edge, allowOnlineFallback: true, policyVersion: 2),
    );
    await MirrorAppSettings(prefs).setTtsPreferences(
      const TtsPreferences(primary: TtsSelection.edge, allowOnlineFallback: false, policyVersion: 2),
    );
    expect(MirrorAppSettings(prefs).ttsPreferences.primary.engine, 'piper');
  });

  test('a Piper or system primary is never touched', () async {
    final prefs = await _prefs(const TtsPreferences(primary: TtsSelection.faber, secondary: TtsSelection.edge, policyVersion: 2));
    final settings = MirrorAppSettings(prefs);
    expect(settings.ttsPreferences.primary.modelId, 'pt_BR-faber-medium');
  });
}
