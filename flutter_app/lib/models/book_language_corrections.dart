import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/conversion/book_language_uncertain.dart';

/// A language the user fixed for a span of one chapter, in source coordinates.
class PassageLanguageCorrection {
  const PassageLanguageCorrection({
    required this.chapterIndex,
    required this.start,
    required this.end,
    required this.language,
  });
  final int chapterIndex;
  final int start;
  final int end;
  final String language;

  Map<String, dynamic> toJson() => {
    'chapter_index': chapterIndex,
    'start': start,
    'end': end,
    'language': language,
  };

  static PassageLanguageCorrection fromJson(Map<String, dynamic> json) =>
      PassageLanguageCorrection(
        chapterIndex: json['chapter_index'] as int,
        start: json['start'] as int,
        end: json['end'] as int,
        language: json['language'] as String,
      );
}

class BookLanguageDecision {
  const BookLanguageDecision({this.bookLanguage, this.passages = const []});
  final String? bookLanguage;
  final List<PassageLanguageCorrection> passages;

  bool get isEmpty => bookLanguage == null && passages.isEmpty;

  Map<String, dynamic> toJson() => {
    'book_language': ?bookLanguage,
    'passages': [for (final p in passages) p.toJson()],
  };

  static BookLanguageDecision fromJson(Map<String, dynamic> json) =>
      BookLanguageDecision(
        bookLanguage: json['book_language'] as String?,
        passages: [
          for (final p in (json['passages'] as List? ?? const []))
            PassageLanguageCorrection.fromJson(Map<String, dynamic>.from(p as Map)),
        ],
      );
}

/// User language corrections, keyed by source-book identity (Apple
/// `BookLanguageCorrections`). Automatic analysis stays in Rust; this only
/// stores what the user decided and merges it into the conversion options.
class BookLanguageCorrections {
  BookLanguageCorrections(this._prefs);
  final SharedPreferences _prefs;
  static const preferenceKey = 'book.languageCorrections.v1';

  Map<String, BookLanguageDecision> _all() {
    final raw = _prefs.getString(preferenceKey);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          e.key as String: BookLanguageDecision.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, BookLanguageDecision> all) =>
      _prefs.setString(
        preferenceKey,
        jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}),
      );

  BookLanguageDecision decision(String bookId) =>
      _all()[bookId] ?? const BookLanguageDecision();

  /// Sets the book language, or one passage's language when [passage] is
  /// given. An empty or null [language] is "Automatic detection": it removes
  /// the correction. A new passage replaces the overlapping parts of older ones.
  Future<void> set(
    String? language, {
    required String bookId,
    PassageLanguageCorrection? passage,
  }) async {
    final all = _all();
    final current = all[bookId] ?? const BookLanguageDecision();
    final chosen = (language == null || language.isEmpty) ? null : language;
    var bookLanguage = current.bookLanguage;
    var passages = current.passages;
    if (passage != null) {
      passages = [
        for (final previous in passages)
          ..._split(previous, passage),
        if (chosen != null)
          PassageLanguageCorrection(
            chapterIndex: passage.chapterIndex,
            start: passage.start,
            end: passage.end,
            language: chosen,
          ),
      ];
    } else {
      bookLanguage = chosen;
    }
    all[bookId] = BookLanguageDecision(
      bookLanguage: bookLanguage,
      passages: passages,
    );
    await _save(all);
  }

  static List<PassageLanguageCorrection> _split(
    PassageLanguageCorrection previous,
    PassageLanguageCorrection next,
  ) {
    if (previous.chapterIndex != next.chapterIndex ||
        !(previous.start < next.end && next.start < previous.end)) {
      return [previous];
    }
    return [
      if (previous.start < next.start)
        PassageLanguageCorrection(
          chapterIndex: previous.chapterIndex,
          start: previous.start,
          end: next.start,
          language: previous.language,
        ),
      if (previous.end > next.end)
        PassageLanguageCorrection(
          chapterIndex: previous.chapterIndex,
          start: next.end,
          end: previous.end,
          language: previous.language,
        ),
    ];
  }

  /// Forgets every correction of one book; other books keep theirs.
  Future<void> remove(String bookId) async {
    final all = _all();
    if (all.remove(bookId) == null) return;
    await _save(all);
  }

  /// Merges the book's decision into Rust conversion options JSON. An explicit
  /// per-job `language` stays authoritative; passage corrections come first.
  String applying(String optionsJson, {required String bookId}) {
    final decision = this.decision(bookId);
    if (decision.isEmpty) return optionsJson;
    final options = Map<String, dynamic>.from(jsonDecode(optionsJson) as Map);
    final explicit = options['language'];
    if ((explicit is! String || explicit.isEmpty) &&
        decision.bookLanguage != null) {
      options['language'] = decision.bookLanguage;
    }
    if (decision.passages.isNotEmpty) {
      options['language_overrides'] = [
        for (final p in decision.passages) p.toJson(),
        ...((options['language_overrides'] as List?) ?? const []),
      ];
    }
    return jsonEncode(options);
  }
}

/// The evidence block of the shared Rust "language remains inconclusive"
/// failure: which passage the user should classify (all null = whole book).
class BookLanguageUncertain {
  const BookLanguageUncertain({this.chapterIndex, this.start, this.end});
  final int? chapterIndex;
  final int? start;
  final int? end;

  static BookLanguageUncertain? decode(Object error) {
    final text = error.toString();
    const open = '[[$bookLanguageUncertainMarker]]';
    const close = '[[/$bookLanguageUncertainMarker]]';
    final from = text.indexOf(open);
    if (from < 0) return null;
    final to = text.indexOf(close, from + open.length);
    if (to < 0) return null;
    try {
      final json = jsonDecode(text.substring(from + open.length, to));
      if (json is! Map) return null;
      return BookLanguageUncertain(
        chapterIndex: json['chapter_index'] as int?,
        start: json['start'] as int?,
        end: json['end'] as int?,
      );
    } catch (_) {
      return null;
    }
  }

  PassageLanguageCorrection? passage(String language) {
    final chapter = chapterIndex;
    final from = start;
    final to = end;
    if (chapter == null || from == null || to == null) return null;
    if (chapter < 0 || from < 0 || to <= from) return null;
    return PassageLanguageCorrection(
      chapterIndex: chapter,
      start: from,
      end: to,
      language: language,
    );
  }
}
