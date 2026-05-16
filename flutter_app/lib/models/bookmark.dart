// Mirror of ios/EpubToMp3/EpubToMp3/Models/Bookmark.swift
//
// A single bookmark or text highlight. When `selectedText` is non-empty
// the entry is a highlight; otherwise it is a plain position bookmark.
// Persisted as JSON via BookmarkStore in SharedPreferences under
// "bookmarks.v1".

import 'package:freezed_annotation/freezed_annotation.dart';

part 'bookmark.freezed.dart';
part 'bookmark.g.dart';

/// Highlight marker colour — mirrors `HighlightColor` in Swift.
@JsonEnum(alwaysCreate: true)
enum HighlightColor {
  yellow,
  blue,
  green,
  pink,
  orange;
}

@unfreezed
class Bookmark with _$Bookmark {
  Bookmark._();

  factory Bookmark({
    required String id,
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    @Default(0) int startChar,
    @Default(0) int endChar,
    @Default('') String selectedText,
    String? note,
    @Default(HighlightColor.yellow) HighlightColor color,
    required DateTime createdAt,
  }) = _Bookmark;

  factory Bookmark.fromJson(Map<String, dynamic> json) =>
      _$BookmarkFromJson(json);

  /// A highlight has user-selected text; a plain bookmark does not.
  bool get isHighlight => selectedText.isNotEmpty;
}
