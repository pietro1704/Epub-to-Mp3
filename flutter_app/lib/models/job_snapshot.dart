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
  }) = _ChapterProgress;

  factory ChapterProgress.fromJson(Map<String, dynamic> json) =>
      _$ChapterProgressFromJson(json);

  String get displayTitle =>
      (name != null && name!.isNotEmpty)
          ? FallbackChapterName.localizedGenerated(name!) ??
                name!.trim()
          : FallbackChapterName.of(index + 1);

  bool get isCompleted =>
      (status?.toLowerCase() == 'completed') ||
      ((downloadUrl?.isNotEmpty ?? false) &&
          (progressRatio != null && progressRatio! >= 0.999));
}
