import 'package:freezed_annotation/freezed_annotation.dart';
import 'fallback_chapter_name.dart';

part 'ebook_fulltext.freezed.dart';
part 'ebook_fulltext.g.dart';

/// Sentence span — produced by `splitSentences()` or projected from a backend
/// segment table. Used by SyncEngine for highlight + ReaderView for rendering.
@freezed
abstract class SentenceSpan with _$SentenceSpan {
  const factory SentenceSpan({
    required String id,
    required String text,
    required int startChar,
    required int endChar,
  }) = _SentenceSpan;
}

@freezed
abstract class FulltextSegment with _$FulltextSegment {
  const factory FulltextSegment({
    String? id,
    required String text,
    int? startMs,
    int? endMs,
  }) = _FulltextSegment;

  factory FulltextSegment.fromJson(Map<String, dynamic> json) =>
      _$FulltextSegmentFromJson(json);
}

/// One footnote body of a chapter, as extracted by the shared Rust parser.
@freezed
abstract class FulltextFootnote with _$FulltextFootnote {
  const factory FulltextFootnote({String? number, required String text}) =
      _FulltextFootnote;

  factory FulltextFootnote.fromJson(Map<String, dynamic> json) =>
      _$FulltextFootnoteFromJson(json);
}

int _flexInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

@freezed
abstract class FulltextChapter with _$FulltextChapter {
  const FulltextChapter._();
  const factory FulltextChapter({
    @JsonKey(fromJson: _flexInt) required int index,
    String? name,
    required String text,
    String? html,
    String? css,
    int? charCount,
    List<FulltextSegment>? segments,
    List<FulltextFootnote>? footnotes,
  }) = _FulltextChapter;

  factory FulltextChapter.fromJson(Map<String, dynamic> json) =>
      _$FulltextChapterFromJson(json);

  /// The reader shows its Footnotes action only for chapters with notes.
  bool get hasFootnotes => footnotes?.isNotEmpty ?? false;

  String get displayTitle {
    final candidate = name?.trim();
    if (candidate == null || candidate.isEmpty || _looksLikeMimeType(candidate)) {
      return FallbackChapterName.of(index);
    }
    return FallbackChapterName.localizedGenerated(candidate) ?? candidate;
  }

  static bool _looksLikeMimeType(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.startsWith('application/') ||
        normalized.startsWith('text/') ||
        normalized.startsWith('image/') ||
        normalized.startsWith('audio/') ||
        normalized.startsWith('video/');
  }

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

/// One nav/NCX entry; [chapterIndex] is the 1-based position in `chapters`.
@freezed
abstract class FulltextTocEntry with _$FulltextTocEntry {
  const factory FulltextTocEntry({
    required String title,
    @Default(1) int level,
    int? chapterIndex,
    @Default(<FulltextTocEntry>[]) List<FulltextTocEntry> children,
  }) = _FulltextTocEntry;

  factory FulltextTocEntry.fromJson(Map<String, dynamic> json) =>
      _$FulltextTocEntryFromJson(json);
}

@freezed
abstract class EbookFulltext with _$EbookFulltext {
  const factory EbookFulltext({
    required String jobId,
    String? bookTitle,
    String? bookAuthor,
    required List<FulltextChapter> chapters,

    /// The book's own contents list (nav/NCX); empty when the book has none.
    @Default(<FulltextTocEntry>[]) List<FulltextTocEntry> toc,

    /// PDF pages without selectable text that the shared parser left out; 0 for EPUBs.
    @Default(0) @JsonKey(name: 'skipped_pages') int skippedPages,
  }) = _EbookFulltext;

  factory EbookFulltext.fromJson(Map<String, dynamic> json) =>
      _$EbookFulltextFromJson(json);
}
