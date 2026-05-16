// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bookmark.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$BookmarkImpl _$$BookmarkImplFromJson(Map<String, dynamic> json) =>
    _$BookmarkImpl(
      id: json['id'] as String,
      bookId: json['bookId'] as String,
      chapterIndex: (json['chapterIndex'] as num).toInt(),
      chapterTitle: json['chapterTitle'] as String,
      startChar: (json['startChar'] as num?)?.toInt() ?? 0,
      endChar: (json['endChar'] as num?)?.toInt() ?? 0,
      selectedText: json['selectedText'] as String? ?? '',
      note: json['note'] as String?,
      color:
          $enumDecodeNullable(_$HighlightColorEnumMap, json['color']) ??
          HighlightColor.yellow,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$$BookmarkImplToJson(_$BookmarkImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'bookId': instance.bookId,
      'chapterIndex': instance.chapterIndex,
      'chapterTitle': instance.chapterTitle,
      'startChar': instance.startChar,
      'endChar': instance.endChar,
      'selectedText': instance.selectedText,
      'note': instance.note,
      'color': _$HighlightColorEnumMap[instance.color]!,
      'createdAt': instance.createdAt.toIso8601String(),
    };

const _$HighlightColorEnumMap = {
  HighlightColor.yellow: 'yellow',
  HighlightColor.blue: 'blue',
  HighlightColor.green: 'green',
  HighlightColor.pink: 'pink',
  HighlightColor.orange: 'orange',
};
