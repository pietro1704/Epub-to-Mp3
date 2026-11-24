import 'package:shared_preferences/shared_preferences.dart';

import '../../models/language_model_choices.dart';
import '../../models/tts_preferences.dart';

/// Set once the global primary voice has been moved to the per-language choices.
const globalVoiceMigratedKey = 'voice.globalMenusMigrated.v1';

/// The global primary/reserve voice menus leave the Models screen (voice per language). What the
/// user had chosen there is kept: a specific Piper primary becomes the choice of the languages
/// that model serves (unless one is already set) and the primary goes back to the automatic
/// Piper entry, which Rust resolves by book language. The reserve voice, the consent and an
/// automatic or Edge primary (no language to move it to) are left as they are. Runs once.
Future<void> migrateGlobalVoiceToLanguageChoices({
  required SharedPreferences prefs,
  required TtsPreferences? configured,
  required List<Map<String, dynamic>> models,
  required TtsSelection? Function(String language) choiceFor,
  required void Function(String language, TtsSelection selection) choose,
  required Future<void> Function(TtsPreferences preferences) savePreferences,
}) async {
  if (prefs.getBool(globalVoiceMigratedKey) == true) return;
  await prefs.setBool(globalVoiceMigratedKey, true);
  final preferences = configured;
  if (preferences == null) return;
  final primary = preferences.primary;
  final modelId = primary.modelId;
  if (primary.engine != 'piper' ||
      modelId == null ||
      primary.representsSameRequest(TtsSelection.automaticPiper)) {
    return;
  }
  final model = models.where((m) => m['id'] == modelId && m['engine'] == 'piper').firstOrNull;
  if (model == null) return;
  final languages = {
    for (final tag in (model['languages'] as List? ?? const []))
      LanguageModelChoices.baseLanguage('$tag'),
  };
  for (final language in languages) {
    if (language.isNotEmpty && choiceFor(language) == null) {
      choose(language, TtsSelection(engine: 'piper', modelId: modelId));
    }
  }
  await savePreferences(preferences.withPrimary(TtsSelection.automaticPiper));
}
