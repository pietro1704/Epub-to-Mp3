// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_record.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$SessionRecordImpl _$$SessionRecordImplFromJson(Map<String, dynamic> json) =>
    _$SessionRecordImpl(
      timestamp: json['timestamp'] as String,
      bookTitle: json['book_title'] as String,
      engine: json['engine'] as String?,
      chaptersConverted: (json['chapters_converted'] as num?)?.toInt(),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      outcome: json['outcome'] as String?,
      mode: json['mode'] as String?,
    );

Map<String, dynamic> _$$SessionRecordImplToJson(_$SessionRecordImpl instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp,
      'book_title': instance.bookTitle,
      'engine': instance.engine,
      'chapters_converted': instance.chaptersConverted,
      'duration_seconds': instance.durationSeconds,
      'outcome': instance.outcome,
      'mode': instance.mode,
    };

_$SessionsResponseImpl _$$SessionsResponseImplFromJson(
  Map<String, dynamic> json,
) => _$SessionsResponseImpl(
  sessions: (json['sessions'] as List<dynamic>)
      .map((e) => SessionRecord.fromJson(e as Map<String, dynamic>))
      .toList(),
  count: (json['count'] as num).toInt(),
);

Map<String, dynamic> _$$SessionsResponseImplToJson(
  _$SessionsResponseImpl instance,
) => <String, dynamic>{'sessions': instance.sessions, 'count': instance.count};
