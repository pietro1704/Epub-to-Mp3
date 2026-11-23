import 'dart:convert';

import 'tts_preferences.dart';

/// The user's explicit narration choice per base book language
/// (`docs/models-by-language-contract.md`, section 4). Absent means automatic.
///
/// The store never decides anything: Rust's resolver validates every stored
/// choice at job start and skips, without deleting, one that is no longer
/// installed or compatible.
class LanguageModelChoices {
  const LanguageModelChoices([this.byLanguage = const {}]);

  static const empty = LanguageModelChoices();

  /// Preference key; the same JSON object as Apple's `languageModelChoices.v1`.
  static const storageKey = 'languageModelChoices.v1';

  /// Base language tag (`pt`, `en`) to its selection.
  final Map<String, TtsSelection> byLanguage;

  /// `pt-BR`, `pt_BR` and `PT` all map to `pt`.
  static String baseLanguage(String tag) {
    final trimmed = tag.trim().toLowerCase();
    final cut = trimmed.indexOf(RegExp('[-_]'));
    return cut < 0 ? trimmed : trimmed.substring(0, cut);
  }

  TtsSelection? choiceFor(String language) => byLanguage[baseLanguage(language)];

  LanguageModelChoices withChoice(String language, TtsSelection selection) {
    final base = baseLanguage(language);
    if (base.isEmpty) return this;
    return LanguageModelChoices({...byLanguage, base: selection});
  }

  /// Back to automatic for [language].
  LanguageModelChoices without(String language) {
    final base = baseLanguage(language);
    if (!byLanguage.containsKey(base)) return this;
    return LanguageModelChoices({...byLanguage}..remove(base));
  }

  /// Tolerant of any stored value: invalid JSON is empty, and an invalid entry
  /// is skipped without discarding its valid neighbours.
  factory LanguageModelChoices.parse(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return empty;
    }
    if (decoded is! Map) return empty;
    final choices = <String, TtsSelection>{};
    for (final entry in decoded.entries) {
      final key = baseLanguage('${entry.key}');
      final value = entry.value;
      if (key.isEmpty || value is! Map) continue;
      try {
        choices[key] = TtsSelection.fromJson(Map<String, dynamic>.from(value));
      } on Object {
        continue;
      }
    }
    return LanguageModelChoices(choices);
  }

  String encode() => jsonEncode({
    for (final entry in byLanguage.entries) entry.key: entry.value.toJson(),
  });
}
