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

/// How the whole book is written (Rust's whole-book detector, BOOK-LANGUAGE-PROFILE).
enum BookLanguageClass {
  monolingual,
  bilingual,
  multilingual;

  static BookLanguageClass parse(Object? value) =>
      BookLanguageClass.values.firstWhere(
        (candidate) => candidate.name == value,
        orElse: () => BookLanguageClass.monolingual,
      );
}

/// One language of the book and its share of the detected text.
class BookLanguageShare {
  const BookLanguageShare({required this.language, required this.fraction});
  final String language;
  final double fraction;
}

/// The `profile` Rust adds (additively) to the book language analysis: a monolingual book is read
/// with its main voice whatever quotations it holds; a bilingual or multilingual one lists every
/// language it is written in, so the missing models are known before playing.
class BookLanguageProfile {
  const BookLanguageProfile({
    required this.classification,
    required this.languages,
    this.primary,
    this.incidental = const [],
  });
  final BookLanguageClass classification;
  final String? primary;
  final List<BookLanguageShare> languages;
  final List<String> incidental;

  factory BookLanguageProfile.fromJson(Map<String, dynamic> json) =>
      BookLanguageProfile(
        classification: BookLanguageClass.parse(json['class']),
        primary: json['primary'] as String?,
        languages: [
          for (final entry in (json['languages'] as List?) ?? const [])
            if (entry is Map && entry['language'] is String)
              BookLanguageShare(
                language: entry['language'] as String,
                fraction: (entry['fraction'] as num?)?.toDouble() ?? 0,
              ),
        ],
        incidental: [
          for (final tag in (json['incidental'] as List?) ?? const [])
            tag as String,
        ],
      );

  Map<String, dynamic> toJson() => {
    'class': classification.name,
    'primary': primary,
    'languages': [
      for (final share in languages)
        {'language': share.language, 'fraction': share.fraction},
    ],
    'incidental': incidental,
  };
}

/// `converter_book_language_json_v1`: what Rust detected in the book file.
/// The language a book is narrated in: what the user corrected, else the primary of the
/// whole-book profile, else the language Rust confirmed. The detected `languages` are an
/// alphabetical set (its first entry is not the main language) and `declared` is only the
/// file's metadata, so neither is ever used to pick the narration. Null when none is known.
String? primaryBookLanguage(BookLanguageAnalysis analysis, {String? corrected}) {
  for (final candidate in [corrected, analysis.profile?.primary, analysis.confirmed]) {
    if (candidate != null && candidate.trim().isNotEmpty) return candidate;
  }
  return null;
}

class BookLanguageAnalysis {
  const BookLanguageAnalysis({
    required this.languages,
    this.declared,
    this.confirmed,
    this.samplesExamined = 0,
    this.inconclusiveSamples = 0,
    this.detector,
    this.profile,
    this.raw,
  });

  /// The whole JSON Rust produced, kept as is: the narration plan takes the analysis and its
  /// profile back verbatim (details this class does not model reach Rust intact).
  final Map<String, dynamic>? raw;

  /// [raw] when the analysis came from Rust, else what this class models.
  Map<String, dynamic> get rawJson => raw ?? toJson();

  /// Whole-book profile; null for a Rust that predates it.
  final BookLanguageProfile? profile;

  final String? declared;

  /// The language Rust confirmed; null means the user must pick one.
  final String? confirmed;
  final List<String> languages;
  final int samplesExamined;
  final int inconclusiveSamples;
  final String? detector;

  factory BookLanguageAnalysis.fromJson(Map<String, dynamic> json) =>
      BookLanguageAnalysis(
        raw: Map<String, dynamic>.unmodifiable(json),
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
        profile: json['profile'] is Map
            ? BookLanguageProfile.fromJson(
                Map<String, dynamic>.from(json['profile'] as Map),
              )
            : null,
      );

  Map<String, dynamic> toJson() =>
      raw ??
      {
        'declared': declared,
        'confirmed': confirmed,
        'languages': languages,
        'samples_examined': samplesExamined,
        'inconclusive_samples': inconclusiveSamples,
        'detector': detector,
        if (profile != null) 'profile': profile!.toJson(),
      };

  factory BookLanguageAnalysis.parse(String json) =>
      BookLanguageAnalysis.fromJson(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
}
