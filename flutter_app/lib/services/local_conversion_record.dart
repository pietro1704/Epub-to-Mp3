import 'dart:convert';

import '../models/tts_preferences.dart';

enum LocalConversionJobStatus { pending, running, completed, failed, cancelled }

class LocalConversionChapterSpec {
  const LocalConversionChapterSpec(this.index, this.name);
  final int index;
  final String name;
}

class LocalConversionChapter {
  const LocalConversionChapter({
    required this.index,
    required this.name,
    this.status = 'pending',
    this.outputPath,
    this.error,
    this.updatedAt,
    this.usedSelections = const [],
    this.fallbackUsed = false,
  });

  final List<TtsSelection> usedSelections;
  final bool fallbackUsed;
  final int index;
  final String name;
  final String status;
  final String? outputPath;
  final String? error;
  final DateTime? updatedAt;

  LocalConversionChapter copyWith({
    List<TtsSelection>? usedSelections,
    bool? fallbackUsed,
    String? status,
    String? outputPath,
    String? error,
    DateTime? updatedAt,
    bool clearError = false,
  }) => LocalConversionChapter(
    usedSelections: usedSelections ?? this.usedSelections,
    fallbackUsed: fallbackUsed ?? this.fallbackUsed,
    index: index,
    name: name,
    status: status ?? this.status,
    outputPath: outputPath ?? this.outputPath,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'index': index,
    'name': name,
    'usedSelections': usedSelections
        .map((selection) => selection.toJson())
        .toList(),
    'fallbackUsed': fallbackUsed,
    'status': status,
    if (outputPath != null) 'outputPath': outputPath,
    if (error != null) 'error': error,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  factory LocalConversionChapter.fromJson(Map<String, dynamic> json) =>
      LocalConversionChapter(
        usedSelections: (json['usedSelections'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (value) =>
                  TtsSelection.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(),
        fallbackUsed: json['fallbackUsed'] == true,
        index: json['index'] as int,
        name: json['name'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
        outputPath: json['outputPath'] as String?,
        error: json['error'] as String?,
        updatedAt: _date(json['updatedAt']),
      );
}

class LocalConversionJob {
  const LocalConversionJob({
    required this.bookId,
    required this.jobId,
    required this.chapters,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.bookTitle,
    this.mode,
    this.manifestUsedSelections = const [],
    this.manifestFallbackUsed = false,
    this.conversionOptionsJson,
    this.ttsPolicyState,
    this.fallbackNoticeShown = false,
    this.currentChapterIndex,
    this.completedOutputs = const [],
    this.error,
    this.lastActivityAt,
  });

  final String bookId;
  final String jobId;
  final String? bookTitle;
  final String? mode;
  final List<TtsSelection> manifestUsedSelections;
  final bool manifestFallbackUsed;
  final List<LocalConversionChapter> chapters;
  final LocalConversionJobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? conversionOptionsJson;
  final Map<String, dynamic>? ttsPolicyState;
  final bool fallbackNoticeShown;
  bool get fallbackUsed =>
      manifestFallbackUsed || chapters.any((chapter) => chapter.fallbackUsed);
  List<TtsSelection> get usedSelections {
    final unique = <String, TtsSelection>{};
    for (final selection in manifestUsedSelections) {
      unique[jsonEncode(selection.toJson())] = selection;
    }
    for (final chapter in chapters) {
      for (final selection in chapter.usedSelections) {
        unique[jsonEncode(selection.toJson())] = selection;
      }
    }
    return unique.values.toList(growable: false);
  }

  final int? currentChapterIndex;
  final List<String> completedOutputs;
  final String? error;
  final DateTime? lastActivityAt;

  LocalConversionJob copyWith({
    String? conversionOptionsJson,
    Map<String, dynamic>? ttsPolicyState,
    bool? fallbackNoticeShown,
    List<LocalConversionChapter>? chapters,
    LocalConversionJobStatus? status,
    DateTime? updatedAt,
    int? currentChapterIndex,
    List<String>? completedOutputs,
    String? error,
    DateTime? lastActivityAt,
    bool clearError = false,
  }) => LocalConversionJob(
    bookId: bookId,
    jobId: jobId,
    bookTitle: bookTitle,
    mode: mode,
    manifestUsedSelections: manifestUsedSelections,
    manifestFallbackUsed: manifestFallbackUsed,
    conversionOptionsJson: conversionOptionsJson ?? this.conversionOptionsJson,
    ttsPolicyState: ttsPolicyState ?? this.ttsPolicyState,
    fallbackNoticeShown: fallbackNoticeShown ?? this.fallbackNoticeShown,
    chapters: chapters ?? this.chapters,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
    completedOutputs: completedOutputs ?? this.completedOutputs,
    error: clearError ? null : (error ?? this.error),
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
  );

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'jobId': jobId,
    'bookTitle': ?bookTitle,
    'mode': ?mode,
    if (manifestUsedSelections.isNotEmpty)
      'manifestUsedSelections': manifestUsedSelections
          .map((selection) => selection.toJson())
          .toList(),
    if (manifestFallbackUsed) 'manifestFallbackUsed': true,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (currentChapterIndex != null) 'currentChapterIndex': currentChapterIndex,
    'completedOutputs': completedOutputs,
    'conversionOptionsJson': ?conversionOptionsJson,
    'ttsPolicyState': ?ttsPolicyState,
    'fallbackNoticeShown': fallbackNoticeShown,
    'fallbackUsed': fallbackUsed,
    if (error != null) 'error': error,
    if (lastActivityAt != null)
      'lastActivityAt': lastActivityAt!.toIso8601String(),
  };

  factory LocalConversionJob.fromJson(
    Map<String, dynamic> json,
  ) => LocalConversionJob(
    ttsPolicyState: json['ttsPolicyState'] is Map
        ? Map<String, dynamic>.from(json['ttsPolicyState'] as Map)
        : null,
    fallbackNoticeShown: json['fallbackNoticeShown'] == true,
    conversionOptionsJson:
        json['conversionOptionsJson'] as String? ??
        _legacyConversionOptions(json),
    bookId: json['bookId'] as String,
    jobId: json['jobId'] as String,
    bookTitle: json['bookTitle'] as String?,
    mode: json['mode'] as String?,
    manifestUsedSelections: (json['manifestUsedSelections'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => TtsSelection.fromJson(Map<String, dynamic>.from(value)))
        .toList(),
    manifestFallbackUsed: json['manifestFallbackUsed'] == true,
    chapters: (json['chapters'] as List<dynamic>)
        .map((c) => LocalConversionChapter.fromJson(c as Map<String, dynamic>))
        .toList(),
    status: LocalConversionJobStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => LocalConversionJobStatus.pending,
    ),
    createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
    updatedAt: _date(json['updatedAt']) ?? DateTime.now().toUtc(),
    currentChapterIndex: json['currentChapterIndex'] as int?,
    completedOutputs: (json['completedOutputs'] as List<dynamic>? ?? const [])
        .cast<String>(),
    error: json['error'] as String?,
    lastActivityAt: _date(json['lastActivityAt']),
  );
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value as String);

/// Only migrate a legacy voice when its identity is actually recorded.
String? _legacyConversionOptions(Map<String, dynamic> json) {
  final engine = json['engine'];
  final voice = json['voice'];
  final model = json['model_id'] ?? json['modelId'];
  if ((engine == 'edge' && voice is String && voice.isNotEmpty) ||
      (engine == 'piper' && model is String && model.isNotEmpty)) {
    return jsonEncode({
      'tts_preferences': {
        'primary': {
          'engine': engine,
          'model_id': engine == 'piper' ? model : null,
          'voice': engine == 'edge' ? voice : null,
        },
        'secondary': null,
        'allow_online_fallback': false,
      },
      if (json['language'] != null) 'language': json['language'],
    });
  }
  return null;
}
