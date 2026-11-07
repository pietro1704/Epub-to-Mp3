// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ebook_fulltext.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_FulltextSegment _$FulltextSegmentFromJson(Map<String, dynamic> json) =>
    _FulltextSegment(
      id: json['id'] as String?,
      text: json['text'] as String,
      startMs: (json['startMs'] as num?)?.toInt(),
      endMs: (json['endMs'] as num?)?.toInt(),
    );

Map<String, dynamic> _$FulltextSegmentToJson(_FulltextSegment instance) =>
    <String, dynamic>{
      'id': instance.id,
      'text': instance.text,
      'startMs': instance.startMs,
      'endMs': instance.endMs,
    };

_FulltextChapter _$FulltextChapterFromJson(Map<String, dynamic> json) =>
    _FulltextChapter(
      index: _flexInt(json['index']),
      name: json['name'] as String?,
      text: json['text'] as String,
      html: json['html'] as String?,
      css: json['css'] as String?,
      charCount: (json['charCount'] as num?)?.toInt(),
      segments: (json['segments'] as List<dynamic>?)
          ?.map((e) => FulltextSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$FulltextChapterToJson(_FulltextChapter instance) =>
    <String, dynamic>{
      'index': instance.index,
      'name': instance.name,
      'text': instance.text,
      'html': instance.html,
      'css': instance.css,
      'charCount': instance.charCount,
      'segments': instance.segments,
    };

_EbookFulltext _$EbookFulltextFromJson(Map<String, dynamic> json) =>
    _EbookFulltext(
      jobId: json['jobId'] as String,
      bookTitle: json['bookTitle'] as String?,
      bookAuthor: json['bookAuthor'] as String?,
      chapters: (json['chapters'] as List<dynamic>)
          .map((e) => FulltextChapter.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$EbookFulltextToJson(_EbookFulltext instance) =>
    <String, dynamic>{
      'jobId': instance.jobId,
      'bookTitle': instance.bookTitle,
      'bookAuthor': instance.bookAuthor,
      'chapters': instance.chapters,
    };
