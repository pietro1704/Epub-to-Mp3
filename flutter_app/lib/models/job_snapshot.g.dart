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
      textOffset: (json['textOffset'] as num?)?.toInt(),
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
      'textOffset': instance.textOffset,
    };
