import 'package:freezed_annotation/freezed_annotation.dart';

part 'ebook_fulltext.freezed.dart';
part 'ebook_fulltext.g.dart';

/// Sentence span — produced by `splitSentences()` or projected from a backend
/// segment table. Used by SyncEngine for highlight + ReaderView for rendering.
@freezed
class SentenceSpan with _$SentenceSpan {
  const factory SentenceSpan({
    required String id,
    required String text,
    required int startChar,
    required int endChar,
  }) = _SentenceSpan;
}

@freezed
class FulltextSegment with _$FulltextSegment {
  const factory FulltextSegment({
    String? id,
    required String text,
    int? startMs,
    int? endMs,
  }) = _FulltextSegment;

  factory FulltextSegment.fromJson(Map<String, dynamic> json) =>
      _$FulltextSegmentFromJson(json);
}

@freezed
class FulltextChapter with _$FulltextChapter {
  const FulltextChapter._();
  const factory FulltextChapter({
    required int index,
    String? name,
    required String text,
    String? html,
    String? css,
    int? charCount,
    List<FulltextSegment>? segments,
  }) = _FulltextChapter;

  factory FulltextChapter.fromJson(Map<String, dynamic> json) =>
      _$FulltextChapterFromJson(json);

  String get displayTitle =>
      (name != null && name!.isNotEmpty) ? name! : 'Chapter $index';

  static String collapseHardWraps(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\n\n', '￾')
        .replaceAll('\n', ' ')
        .replaceAll('￾', '\n\n');
  }

  List<SentenceSpan> splitSentences() {
    final collapsed = collapseHardWraps(text);
    final spans = <SentenceSpan>[];
    final chars = collapsed.runes.toList();
    var start = 0;
    var i = 0;
    var sentenceIdx = 0;
    bool isWs(int code) =>
        code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

    while (i < chars.length) {
      final c = chars[i];
      final isTerminator = c == 0x2E || c == 0x3F || c == 0x21;
      final nextIsBoundary =
          (i + 1 >= chars.length) ? true : isWs(chars[i + 1]);
      if (isTerminator && nextIsBoundary) {
        final endExclusive = i + 1;
        final raw = String.fromCharCodes(chars.sublist(start, endExclusive));
        final trimmed = raw.trim();
        if (trimmed.isNotEmpty) {
          spans.add(SentenceSpan(
            id: '$index:$sentenceIdx',
            text: trimmed,
            startChar: start,
            endChar: endExclusive,
          ));
          sentenceIdx++;
        }
        var j = endExclusive;
        while (j < chars.length && isWs(chars[j])) {
          j++;
        }
        start = j;
        i = j;
        continue;
      }
      i++;
    }
    if (start < chars.length) {
      final raw = String.fromCharCodes(chars.sublist(start));
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty) {
        spans.add(SentenceSpan(
          id: '$index:$sentenceIdx',
          text: trimmed,
          startChar: start,
          endChar: chars.length,
        ));
      }
    }
    return spans;
  }
}

@freezed
class EbookFulltext with _$EbookFulltext {
  const factory EbookFulltext({
    required String jobId,
    String? bookTitle,
    String? bookAuthor,
    required List<FulltextChapter> chapters,
  }) = _EbookFulltext;

  factory EbookFulltext.fromJson(Map<String, dynamic> json) =>
      _$EbookFulltextFromJson(json);
}
