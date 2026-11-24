import 'dart:convert';

import 'tts_preferences.dart';

/// `docs/models-by-language-contract.md`: Rust owns the resolution; these types
/// only carry the request and decode the answer.

/// One base language that has at least one catalog model on this platform.
class TtsCatalogLanguage {
  const TtsCatalogLanguage({
    required this.tag,
    required this.modelCount,
    this.routingTags = const [],
    this.popularityRank,
  });

  final String tag;
  final int modelCount;
  final List<String> routingTags;

  /// Position in Rust's shared popularity list (1 = most popular); null when not ranked.
  final int? popularityRank;

  factory TtsCatalogLanguage.fromJson(Map<String, dynamic> json) =>
      TtsCatalogLanguage(
        tag: json['tag'] as String,
        modelCount: (json['model_count'] as num?)?.toInt() ?? 0,
        popularityRank: (json['popularity_rank'] as num?)?.toInt(),
        routingTags: [
          for (final tag in (json['routing_tags'] as List?) ?? const [])
            tag as String,
        ],
      );

  /// Decodes `converter_tts_catalog_languages_json_v1`.
  static List<TtsCatalogLanguage> parseAll(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return [
      for (final entry in (decoded['languages'] as List?) ?? const [])
        TtsCatalogLanguage.fromJson(Map<String, dynamic>.from(entry as Map)),
    ];
  }
}

/// Resolver outcome. Unknown values from a newer Rust decode to [unknown] so a
/// client never crashes on, or silently plays through, an unhandled status.
enum LanguageModelStatus {
  selected,
  systemFallback,
  missingModel,
  unknown;

  static LanguageModelStatus parse(String? value) => switch (value) {
    'selected' => selected,
    'system_fallback' => systemFallback,
    'missing_model' => missingModel,
    _ => unknown,
  };
}

class SuggestedModel {
  const SuggestedModel({
    required this.modelId,
    this.quality,
    this.downloadBytes = 0,
  });

  final String modelId;
  final String? quality;
  final int downloadBytes;

  factory SuggestedModel.fromJson(Map<String, dynamic> json) => SuggestedModel(
    modelId: json['model_id'] as String,
    quality: json['quality'] as String?,
    downloadBytes: (json['download_bytes'] as num?)?.toInt() ?? 0,
  );
}

class MissingLanguageModel {
  const MissingLanguageModel({required this.language, required this.suggested});

  final String language;
  final List<SuggestedModel> suggested;

  factory MissingLanguageModel.fromJson(Map<String, dynamic> json) =>
      MissingLanguageModel(
        language: json['language'] as String,
        suggested: [
          for (final item in (json['suggested'] as List?) ?? const [])
            SuggestedModel.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
      );
}

class LanguageModelResolution {
  const LanguageModelResolution({
    required this.bookLanguage,
    required this.status,
    this.selection,
    this.source,
    this.reasons = const [],
    this.missing,
  });

  final String bookLanguage;
  final LanguageModelStatus status;

  /// The narration to use as the job's primary; absent for `missing_model`.
  final TtsSelection? selection;
  final String? source;
  final List<String> reasons;
  final MissingLanguageModel? missing;

  factory LanguageModelResolution.fromJson(Map<String, dynamic> json) {
    final selection = json['selection'];
    final missing = json['missing'];
    return LanguageModelResolution(
      bookLanguage: json['book_language'] as String? ?? '',
      status: LanguageModelStatus.parse(json['status'] as String?),
      selection: selection is Map
          ? TtsSelection.fromJson(Map<String, dynamic>.from(selection))
          : null,
      source: json['source'] as String?,
      reasons: [
        for (final reason in (json['reasons'] as List?) ?? const [])
          reason as String,
      ],
      missing: missing is Map
          ? MissingLanguageModel.fromJson(Map<String, dynamic>.from(missing))
          : null,
    );
  }

  factory LanguageModelResolution.parse(String json) =>
      LanguageModelResolution.fromJson(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
}

/// Inputs of `converter_tts_resolve_language_model_json_v1`.
class LanguageModelRequest {
  const LanguageModelRequest({
    required this.bookLanguage,
    required this.platform,
    this.perLanguageChoices = const {},
    this.primary,
    this.allowOnlineFallback = false,
    this.allowAutomaticSystemVoiceFallback = true,
    this.installedModelIds = const [],
    this.systemVoices = const [],
    this.androidApi,
  });

  final String bookLanguage;

  /// The `ModelPlatform` name: `Android`, `Ios`, `Macos`, `Linux`, `Windows`.
  final String platform;
  final Map<String, TtsSelection> perLanguageChoices;
  final TtsSelection? primary;
  final bool allowOnlineFallback;
  final bool allowAutomaticSystemVoiceFallback;
  final List<String> installedModelIds;
  final List<String> systemVoices;
  final int? androidApi;

  static const schemaVersion = 1;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'book_language': bookLanguage,
    'per_language_choices': {
      for (final entry in perLanguageChoices.entries)
        entry.key: entry.value.toJson(),
    },
    'primary': primary?.toJson(),
    'allow_online_fallback': allowOnlineFallback,
    'allow_automatic_system_voice_fallback': allowAutomaticSystemVoiceFallback,
    'installed_model_ids': installedModelIds,
    'system_voices': systemVoices,
    'platform': platform,
    if (androidApi != null) 'android_api': androidApi,
  };
}

/// `converter_book_language_json_v1`: what Rust detected in the book file.
class BookLanguageAnalysis {
  const BookLanguageAnalysis({
    required this.languages,
    this.declared,
    this.confirmed,
    this.samplesExamined = 0,
    this.inconclusiveSamples = 0,
    this.detector,
  });

  final String? declared;

  /// The language Rust confirmed; null means the user must pick one.
  final String? confirmed;
  final List<String> languages;
  final int samplesExamined;
  final int inconclusiveSamples;
  final String? detector;

  factory BookLanguageAnalysis.fromJson(Map<String, dynamic> json) =>
      BookLanguageAnalysis(
        declared: json['declared'] as String?,
        confirmed: json['confirmed'] as String?,
        languages: [
          for (final language in (json['languages'] as List?) ?? const [])
            language as String,
        ],
        samplesExamined: (json['samples_examined'] as num?)?.toInt() ?? 0,
        inconclusiveSamples:
            (json['inconclusive_samples'] as num?)?.toInt() ?? 0,
        detector: json['detector'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'declared': declared,
    'confirmed': confirmed,
    'languages': languages,
    'samples_examined': samplesExamined,
    'inconclusive_samples': inconclusiveSamples,
    'detector': detector,
  };

  factory BookLanguageAnalysis.parse(String json) =>
      BookLanguageAnalysis.fromJson(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
}
