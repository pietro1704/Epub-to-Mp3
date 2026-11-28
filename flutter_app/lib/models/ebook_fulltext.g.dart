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

_FulltextFootnote _$FulltextFootnoteFromJson(Map<String, dynamic> json) =>
    _FulltextFootnote(
      number: json['number'] as String?,
      text: json['text'] as String,
    );

Map<String, dynamic> _$FulltextFootnoteToJson(_FulltextFootnote instance) =>
    <String, dynamic>{'number': instance.number, 'text': instance.text};

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
      footnotes: (json['footnotes'] as List<dynamic>?)
          ?.map((e) => FulltextFootnote.fromJson(e as Map<String, dynamic>))
          .toList(),
      anchors: (json['anchors'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toInt()),
      ),
      sourcePath: json['sourcePath'] as String?,
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
      'footnotes': instance.footnotes,
      'anchors': instance.anchors,
      'sourcePath': instance.sourcePath,
    };

_FulltextTocEntry _$FulltextTocEntryFromJson(Map<String, dynamic> json) =>
    _FulltextTocEntry(
      title: json['title'] as String,
      level: (json['level'] as num?)?.toInt() ?? 1,
      chapterIndex: (json['chapterIndex'] as num?)?.toInt(),
      fragment: json['fragment'] as String?,
      children:
          (json['children'] as List<dynamic>?)
              ?.map((e) => FulltextTocEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <FulltextTocEntry>[],
    );

Map<String, dynamic> _$FulltextTocEntryToJson(_FulltextTocEntry instance) =>
    <String, dynamic>{
      'title': instance.title,
      'level': instance.level,
      'chapterIndex': instance.chapterIndex,
      'fragment': instance.fragment,
      'children': instance.children,
    };

_EbookFulltext _$EbookFulltextFromJson(Map<String, dynamic> json) =>
    _EbookFulltext(
      jobId: json['jobId'] as String,
      bookTitle: json['bookTitle'] as String?,
      bookAuthor: json['bookAuthor'] as String?,
      chapters: (json['chapters'] as List<dynamic>)
          .map((e) => FulltextChapter.fromJson(e as Map<String, dynamic>))
          .toList(),
      toc:
          (json['toc'] as List<dynamic>?)
              ?.map((e) => FulltextTocEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <FulltextTocEntry>[],
      skippedPages: (json['skipped_pages'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$EbookFulltextToJson(_EbookFulltext instance) =>
    <String, dynamic>{
      'jobId': instance.jobId,
      'bookTitle': instance.bookTitle,
      'bookAuthor': instance.bookAuthor,
      'chapters': instance.chapters,
      'toc': instance.toc,
      'skipped_pages': instance.skippedPages,
    };
