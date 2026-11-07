// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'job_snapshot.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ChapterProgress _$ChapterProgressFromJson(Map<String, dynamic> json) =>
    _ChapterProgress(
      index: (json['index'] as num).toInt(),
      name: json['name'] as String?,
      status: json['status'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      chars: (json['chars'] as num?)?.toInt(),
      charsProcessed: (json['charsProcessed'] as num?)?.toInt(),
      progressRatio: (json['progressRatio'] as num?)?.toDouble(),
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      startedAt: (json['startedAt'] as num?)?.toDouble(),
      completedAt: (json['completedAt'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$ChapterProgressToJson(_ChapterProgress instance) =>
    <String, dynamic>{
      'index': instance.index,
      'name': instance.name,
      'status': instance.status,
      'downloadUrl': instance.downloadUrl,
      'chars': instance.chars,
      'charsProcessed': instance.charsProcessed,
      'progressRatio': instance.progressRatio,
      'durationSeconds': instance.durationSeconds,
      'startedAt': instance.startedAt,
      'completedAt': instance.completedAt,
    };

_OutputAsset _$OutputAssetFromJson(Map<String, dynamic> json) => _OutputAsset(
  name: json['name'] as String,
  url: json['url'] as String,
  sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
);

Map<String, dynamic> _$OutputAssetToJson(_OutputAsset instance) =>
    <String, dynamic>{
      'name': instance.name,
      'url': instance.url,
      'sizeBytes': instance.sizeBytes,
    };

_JobSnapshot _$JobSnapshotFromJson(Map<String, dynamic> json) => _JobSnapshot(
  jobId: json['jobId'] as String,
  state: json['state'] as String,
  bookTitle: json['bookTitle'] as String?,
  bookAuthor: json['bookAuthor'] as String?,
  coverUrl: json['coverUrl'] as String?,
  coverMimeType: json['coverMimeType'] as String?,
  engine: json['engine'] as String?,
  voice: json['voice'] as String?,
  language: json['language'] as String?,
  progressPercent: (json['progressPercent'] as num?)?.toDouble(),
  chaptersTotal: (json['chaptersTotal'] as num?)?.toInt(),
  chaptersCompleted: (json['chaptersCompleted'] as num?)?.toInt(),
  chapterProgress: (json['chapterProgress'] as List<dynamic>?)
      ?.map((e) => ChapterProgress.fromJson(e as Map<String, dynamic>))
      .toList(),
  outputs: (json['outputs'] as List<dynamic>?)
      ?.map((e) => OutputAsset.fromJson(e as Map<String, dynamic>))
      .toList(),
  logUrl: json['logUrl'] as String?,
  error: json['error'] as String?,
  lastActivityAt: (json['lastActivityAt'] as num?)?.toDouble(),
);

Map<String, dynamic> _$JobSnapshotToJson(_JobSnapshot instance) =>
    <String, dynamic>{
      'jobId': instance.jobId,
      'state': instance.state,
      'bookTitle': instance.bookTitle,
      'bookAuthor': instance.bookAuthor,
      'coverUrl': instance.coverUrl,
      'coverMimeType': instance.coverMimeType,
      'engine': instance.engine,
      'voice': instance.voice,
      'language': instance.language,
      'progressPercent': instance.progressPercent,
      'chaptersTotal': instance.chaptersTotal,
      'chaptersCompleted': instance.chaptersCompleted,
      'chapterProgress': instance.chapterProgress,
      'outputs': instance.outputs,
      'logUrl': instance.logUrl,
      'error': instance.error,
      'lastActivityAt': instance.lastActivityAt,
    };
