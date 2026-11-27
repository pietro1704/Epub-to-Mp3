import 'package:freezed_annotation/freezed_annotation.dart';

import 'fallback_chapter_name.dart';

part 'job_snapshot.freezed.dart';
part 'job_snapshot.g.dart';

/// One chapter in the playback queue. Wire format is camelCase.
@freezed
abstract class ChapterProgress with _$ChapterProgress {
  const ChapterProgress._();
  const factory ChapterProgress({
    required int index,
    String? name,
    String? status,
    String? downloadUrl,
    int? chars,
    int? charsProcessed,
    double? progressRatio,
    double? durationSeconds,
    double? startedAt,
    double? completedAt,

    /// Unicode scalar offset in the chapter text where this audio starts (a
    /// listening started inside the chapter, e.g. Play from here); 0 or null
    /// for audio of the whole chapter. Mirrors iOS `ChapterProgress.textOffset`.
    int? textOffset,
  }) = _ChapterProgress;

  factory ChapterProgress.fromJson(Map<String, dynamic> json) =>
      _$ChapterProgressFromJson(json);

  static final _titleCharacter = RegExp(r'[\p{L}\p{N}]', unicode: true);

  String get displayTitle {
    final title = name?.trim();
    if (title == null || !_titleCharacter.hasMatch(title)) {
      return FallbackChapterName.of(index + 1);
    }
    return FallbackChapterName.localizedGenerated(title) ?? title;
  }

  bool get isCompleted =>
      (status?.toLowerCase() == 'completed') ||
      ((downloadUrl?.isNotEmpty ?? false) &&
          (progressRatio != null && progressRatio! >= 0.999));
}
