// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_record.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SessionRecord _$SessionRecordFromJson(Map<String, dynamic> json) =>
    _SessionRecord(
      timestamp: json['timestamp'] as String,
      bookTitle: json['book_title'] as String,
      engine: json['engine'] as String?,
      chaptersConverted: (json['chapters_converted'] as num?)?.toInt(),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      outcome: json['outcome'] as String?,
      mode: json['mode'] as String?,
    );

Map<String, dynamic> _$SessionRecordToJson(_SessionRecord instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp,
      'book_title': instance.bookTitle,
      'engine': instance.engine,
      'chapters_converted': instance.chaptersConverted,
      'duration_seconds': instance.durationSeconds,
      'outcome': instance.outcome,
      'mode': instance.mode,
    };

_SessionsResponse _$SessionsResponseFromJson(Map<String, dynamic> json) =>
    _SessionsResponse(
      sessions: (json['sessions'] as List<dynamic>)
          .map((e) => SessionRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      count: (json['count'] as num).toInt(),
    );

Map<String, dynamic> _$SessionsResponseToJson(_SessionsResponse instance) =>
    <String, dynamic>{'sessions': instance.sessions, 'count': instance.count};
