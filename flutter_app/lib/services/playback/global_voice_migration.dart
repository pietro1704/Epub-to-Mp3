import 'package:shared_preferences/shared_preferences.dart';

import '../../models/language_model_choices.dart';
import '../../models/tts_preferences.dart';

/// Set once the global primary voice has been moved to the per-language choices. Its own key
/// (v2) lets users who ran the first, Piper-only version (`voice.globalMenusMigrated.v1`) go
/// through the system/Edge step; repeating the Piper step is harmless.
const globalVoiceMigratedKey = 'voice.globalMenusMigrated.v2';

/// The global primary/reserve voice menus leave the Models screen (voice per language), as in
/// Apple's `GlobalVoiceMigration`. What the user had chosen there is kept: a specific Piper
/// primary becomes the choice of the languages that model serves; a system primary, or an Edge
/// primary with online consent, becomes the choice of the device languages and of the library's
/// analyzed books. An existing choice always wins, and the primary goes back to the automatic
/// Piper entry, which Rust resolves by book language. An Edge primary without consent is never
/// copied. The saved reserve is kept; one that equals the new primary swaps with the old
/// primary so the pair survives. Runs once.
Future<void> migrateGlobalVoiceToLanguageChoices({
  required SharedPreferences prefs,
  required TtsPreferences? configured,
  required List<Map<String, dynamic>> models,
  required TtsSelection? Function(String language) choiceFor,
  required void Function(String language, TtsSelection selection) choose,
  required Future<void> Function(TtsPreferences preferences) savePreferences,
  List<String> deviceLanguages = const [],
  List<String> libraryLanguages = const [],
}) async {
  if (prefs.getBool(globalVoiceMigratedKey) == true) return;
  await prefs.setBool(globalVoiceMigratedKey, true);
  final preferences = configured;
  if (preferences == null) return;
  final primary = preferences.primary;
  final Set<String> languages;
  if (primary.engine == 'piper') {
    final modelId = primary.modelId;
    if (modelId == null ||
        primary.representsSameRequest(TtsSelection.automaticPiper)) {
      return;
    }
    final model = models
        .where((m) => m['id'] == modelId && m['engine'] == 'piper')
        .firstOrNull;
    if (model == null) {
      return;
    }
    languages = {
      for (final tag in (model['languages'] as List? ?? const []))
        LanguageModelChoices.baseLanguage('$tag'),
    };
  } else if (primary.engine == 'system' ||
      (primary.engine == 'edge' && preferences.allowOnlineFallback)) {
    languages = {
      for (final tag in [...deviceLanguages, ...libraryLanguages])
        LanguageModelChoices.baseLanguage(tag),
    };
  } else if (primary.engine == 'edge') {
    languages = const {}; // no consent: never copied, the primary just goes back to Piper
  } else {
    return;
  }
  for (final language in languages) {
    if (language.isNotEmpty && choiceFor(language) == null) {
      choose(
        language,
        primary.engine == 'piper'
            ? TtsSelection(engine: 'piper', modelId: primary.modelId)
            : primary,
      );
    }
  }
  var next = preferences.withPrimary(TtsSelection.automaticPiper);
  if (preferences.secondary != null && next.secondary == null) {
    next = TtsPreferences(
      primary: next.primary,
      secondary: primary,
      allowOnlineFallback: next.allowOnlineFallback,
      policyVersion: next.policyVersion,
      footnoteNarration: next.footnoteNarration, silenceTrim: next.silenceTrim,
    );
  }
  await savePreferences(next);
}
