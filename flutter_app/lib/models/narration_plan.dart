import 'dart:convert';

import 'language_model_resolution.dart';
import 'tts_preferences.dart';

/// Rust's narration plan of one book (`converter_book_narration_plan_json_v1`, card
/// RUST-NARRATION-PLAN): the language decision, the voice that reads the main language (the
/// listener's own voice for this book first), the voice of each other language of the book, and
/// what to tell the listener when a voice is missing. Pure and never downloads; these types only
/// carry the request and decode the answer, every decision is Rust's.

/// Inputs of the plan. The book's [analysis] travels with its whole Rust JSON (`profile` included),
/// so details the client does not model (characters, longest section, role) reach Rust intact.
class NarrationPlanRequest {
  const NarrationPlanRequest({
    required this.platform,
    this.userCorrection,
    this.declared,
    this.analysis,
    this.bookVoice,
    this.perLanguageChoices = const {},
    this.primary,
    this.allowOnlineFallback = false,
    this.allowAutomaticSystemVoiceFallback = true,
    this.installedModelIds = const [],
    this.systemVoices = const [],
    this.androidApi,
  });

  static const schemaVersion = 1;

  /// The language the user set for the whole book.
  final String? userCorrection;
  final String? declared;
  final BookLanguageAnalysis? analysis;

  /// The voice the listener set for this one book (main language only).
  final TtsSelection? bookVoice;
  final Map<String, TtsSelection> perLanguageChoices;
  final TtsSelection? primary;
  final bool allowOnlineFallback;
  final bool allowAutomaticSystemVoiceFallback;
  final List<String> installedModelIds;
  final List<String> systemVoices;
  final String platform;
  final int? androidApi;

  Map<String, dynamic> toJson() {
    final raw = analysis?.rawJson;
    return {
      'schema_version': schemaVersion,
      'user_correction': ?userCorrection,
      'declared': ?(declared ?? analysis?.declared),
      'analysis': ?raw,
      'profile': ?(raw?['profile'] is Map ? raw!['profile'] : null),
      'book_voice': ?bookVoice?.toJson(),
      'per_language_choices': {
        for (final entry in perLanguageChoices.entries)
          entry.key: entry.value.toJson(),
      },
      'primary': ?primary?.toJson(),
      'allow_online_fallback': allowOnlineFallback,
      'allow_automatic_system_voice_fallback': allowAutomaticSystemVoiceFallback,
      'installed_model_ids': installedModelIds,
      'system_voices': systemVoices,
      'platform': platform,
      'android_api': ?androidApi,
    };
  }
}

enum NarrationDecisionSource {
  userCorrection,
  profile,
  confirmed,
  undetermined,
  unknown;

  static NarrationDecisionSource parse(Object? value) => switch (value) {
    'user_correction' => userCorrection,
    'profile' => profile,
    'confirmed' => confirmed,
    'undetermined' => undetermined,
    _ => unknown,
  };
}

class NarrationDecision {
  const NarrationDecision({
    required this.language,
    required this.source,
    this.preselect,
    this.declaredConflict,
  });

  /// The language the book is narrated in; null while nothing determined it.
  final String? language;
  final NarrationDecisionSource source;

  /// Undetermined only: the declared tag, to preselect in the question.
  final String? preselect;

  /// The file declares another base language than the text is written in. Reported, never an alert.
  final String? declaredConflict;

  factory NarrationDecision.fromJson(Map<String, dynamic> json) => NarrationDecision(
    language: json['language'] as String?,
    source: NarrationDecisionSource.parse(json['source']),
    preselect: json['preselect'] as String?,
    declaredConflict: json['declared_conflict'] as String?,
  );
}

enum NarrationLanguageRole {
  main,
  significant,
  section,
  incidental,
  unknown;

  static NarrationLanguageRole parse(Object? value) => switch (value) {
    'main' => main,
    'significant' => significant,
    'section' => section,
    'incidental' => incidental,
    _ => unknown,
  };
}

/// A language of the book that has no usable voice and deserves a notice (significant ones only).
class NarrationMissingNotice {
  const NarrationMissingNotice({required this.language, required this.role});
  final String language;
  final NarrationLanguageRole role;
}

class NarrationPlan {
  const NarrationPlan({
    required this.decision,
    this.main,
    this.languageVoices = const {},
    this.mainMissing = false,
    this.notifyMissing = const [],
    this.needsLanguageQuestion = false,
  });

  final NarrationDecision decision;

  /// How the main language is narrated; null while the language is undetermined.
  final LanguageModelResolution? main;

  /// The voice of each other language of the book that has a usable one (base tag to selection).
  final Map<String, TtsSelection> languageVoices;

  /// The main language has no usable voice: alert before any audio.
  final bool mainMissing;

  /// Significant languages without a voice: one notice per book.
  final List<NarrationMissingNotice> notifyMissing;

  /// Nothing determined the language: ask once, with [NarrationDecision.preselect] chosen.
  final bool needsLanguageQuestion;

  factory NarrationPlan.fromJson(Map<String, dynamic> json) {
    final main = json['main'];
    final voices = json['language_voices'];
    return NarrationPlan(
      decision: NarrationDecision.fromJson(
        Map<String, dynamic>.from(json['decision'] as Map),
      ),
      main: main is Map
          ? LanguageModelResolution.fromJson(Map<String, dynamic>.from(main))
          : null,
      languageVoices: {
        if (voices is Map)
          for (final entry in voices.entries)
            if (entry.value is Map)
              '${entry.key}': TtsSelection.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              ),
      },
      mainMissing: json['main_missing'] == true,
      notifyMissing: [
        for (final notice in (json['notify_missing'] as List?) ?? const [])
          if (notice is Map && notice['language'] is String)
            NarrationMissingNotice(
              language: notice['language'] as String,
              role: NarrationLanguageRole.parse(notice['role']),
            ),
      ],
      needsLanguageQuestion: json['needs_language_question'] == true,
    );
  }

  factory NarrationPlan.parse(String json) =>
      NarrationPlan.fromJson(Map<String, dynamic>.from(jsonDecode(json) as Map));
}
