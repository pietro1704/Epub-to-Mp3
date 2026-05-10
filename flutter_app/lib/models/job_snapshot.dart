import 'package:freezed_annotation/freezed_annotation.dart';

part 'job_snapshot.freezed.dart';
part 'job_snapshot.g.dart';

/// Mirrors `python_app/server.py::JobStatus`. Wire format is camelCase.
@freezed
class ChapterProgress with _$ChapterProgress {
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
      (name != null && name!.isNotEmpty) ? name! : 'Chapter ${index + 1}';

  bool get isCompleted =>
      (status?.toLowerCase() == 'completed') ||
      ((downloadUrl?.isNotEmpty ?? false) &&
          (progressRatio != null && progressRatio! >= 0.999));
}

@freezed
class OutputAsset with _$OutputAsset {
  const OutputAsset._();
  const factory OutputAsset({
    required String name,
    required String url,
    int? sizeBytes,
  }) = _OutputAsset;

  factory OutputAsset.fromJson(Map<String, dynamic> json) =>
      _$OutputAssetFromJson(json);

  bool get isMp3 => name.toLowerCase().endsWith('.mp3');
  bool get isZip => name.toLowerCase().endsWith('.zip');
}

@freezed
class JobSnapshot with _$JobSnapshot {
  const JobSnapshot._();
  const factory JobSnapshot({
    required String jobId,
    required String state,
    String? bookTitle,
    String? bookAuthor,
    String? coverUrl,
    String? coverMimeType,
    String? engine,
    String? voice,
    String? language,
    double? progressPercent,
    int? chaptersTotal,
    int? chaptersCompleted,
    List<ChapterProgress>? chapterProgress,
    List<OutputAsset>? outputs,
    String? logUrl,
    String? error,
    double? lastActivityAt,
  }) = _JobSnapshot;

  factory JobSnapshot.fromJson(Map<String, dynamic> json) =>
      _$JobSnapshotFromJson(json);

  bool get isTerminal {
    final s = state.toLowerCase();
    return s == 'finished' || s == 'failed' || s == 'cancelled';
  }

  List<ChapterProgress> get playableChapters {
    final progress = chapterProgress;
    if (progress != null && progress.isNotEmpty) {
      final filtered =
          progress.where((c) => c.downloadUrl != null).toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      return filtered;
    }
    final outs = outputs;
    if (outs == null) return const [];
    final list = <ChapterProgress>[];
    for (var i = 0; i < outs.length; i++) {
      final asset = outs[i];
      if (!asset.isMp3) continue;
      list.add(ChapterProgress(
        index: i,
        name: asset.name,
        status: 'completed',
        downloadUrl: asset.url,
        progressRatio: 1.0,
      ));
    }
    return list;
  }
}
