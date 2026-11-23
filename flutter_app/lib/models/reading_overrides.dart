import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Reading preferences (appearance and speed) that apply to ONE book and win over
/// the default for all books. A field is null when the book follows the default.
class ReadingOverrides {
  const ReadingOverrides({
    this.theme,
    this.fontFamily,
    this.fontSize,
    this.layout,
    this.lineSpacing,
    this.margin,
    this.alignment,
    this.audioRate,
  });

  static const none = ReadingOverrides();

  final ReaderTheme? theme;
  final ReaderFontFamily? fontFamily;

  /// Step 0..4, as `AppSettings.readerFontSize`.
  final int? fontSize;
  final ReaderLayout? layout;
  final double? lineSpacing;
  final double? margin;
  final ReaderTextAlignment? alignment;
  final double? audioRate;

  bool get isEmpty =>
      theme == null &&
      fontFamily == null &&
      fontSize == null &&
      layout == null &&
      lineSpacing == null &&
      margin == null &&
      alignment == null &&
      audioRate == null;

  ReadingOverrides copyWith({
    ReaderTheme? theme,
    ReaderFontFamily? fontFamily,
    int? fontSize,
    ReaderLayout? layout,
    double? lineSpacing,
    double? margin,
    ReaderTextAlignment? alignment,
    double? audioRate,
  }) => ReadingOverrides(
    theme: theme ?? this.theme,
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    layout: layout ?? this.layout,
    lineSpacing: lineSpacing ?? this.lineSpacing,
    margin: margin ?? this.margin,
    alignment: alignment ?? this.alignment,
    audioRate: audioRate ?? this.audioRate,
  );

  Map<String, Object> toJson() => {
    'theme': ?theme?.rawValue,
    'fontFamily': ?fontFamily?.rawValue,
    'fontSize': ?fontSize,
    'layout': ?layout?.rawValue,
    'lineSpacing': ?lineSpacing,
    'margin': ?margin,
    'alignment': ?alignment?.rawValue,
    'audioRate': ?audioRate,
  };

  factory ReadingOverrides.fromJson(Map<String, dynamic> json) {
    T? named<T extends Enum>(String key, List<T> values) {
      final raw = json[key];
      return raw is String ? values.where((v) => v.name == raw).firstOrNull : null;
    }

    return ReadingOverrides(
      theme: named('theme', ReaderTheme.values),
      fontFamily: named('fontFamily', ReaderFontFamily.values),
      fontSize: (json['fontSize'] as num?)?.toInt().clamp(0, 4),
      layout: named('layout', ReaderLayout.values),
      lineSpacing: (json['lineSpacing'] as num?)?.toDouble().clamp(0, 16).toDouble(),
      margin: (json['margin'] as num?)?.toDouble().clamp(8, 80).toDouble(),
      alignment: named('alignment', ReaderTextAlignment.values),
      audioRate: (json['audioRate'] as num?)?.toDouble().clamp(0.5, 3.0).toDouble(),
    );
  }
}

/// Persists one [ReadingOverrides] per book id.
class BookReadingStore {
  BookReadingStore(this._prefs);
  final SharedPreferences _prefs;

  static String _key(String bookId) => 'bookReading.v1.$bookId';

  ReadingOverrides read(String bookId) {
    final raw = _prefs.getString(_key(bookId));
    if (raw == null) return ReadingOverrides.none;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? ReadingOverrides.fromJson(decoded) : ReadingOverrides.none;
    } on FormatException {
      return ReadingOverrides.none;
    }
  }

  Future<void> write(String bookId, ReadingOverrides overrides) async {
    if (overrides.isEmpty) {
      await _prefs.remove(_key(bookId));
    } else {
      await _prefs.setString(_key(bookId), jsonEncode(overrides.toJson()));
    }
  }
}

/// The settings a book is read with: its own overrides over the default.
class BookScopedAppSettings extends MirrorAppSettings {
  BookScopedAppSettings(super.prefs, this.overrides);

  final ReadingOverrides overrides;

  @override
  ReaderTheme get readerTheme => overrides.theme ?? super.readerTheme;
  @override
  ReaderFontFamily get readerFontFamily => overrides.fontFamily ?? super.readerFontFamily;
  @override
  int get readerFontSize => overrides.fontSize ?? super.readerFontSize;
  @override
  ReaderLayout get readerLayout => overrides.layout ?? super.readerLayout;
  @override
  double get readerLineSpacing => overrides.lineSpacing ?? super.readerLineSpacing;
  @override
  double get readerMargin => overrides.margin ?? super.readerMargin;
  @override
  ReaderTextAlignment get readerTextAlignment => overrides.alignment ?? super.readerTextAlignment;
  @override
  double get audioRate => overrides.audioRate ?? super.audioRate;
  @override
  bool get readerOverrideFontFamily => overrides.fontFamily != null || super.readerOverrideFontFamily;
  @override
  bool get readerOverrideFontSize => overrides.fontSize != null || super.readerOverrideFontSize;
  @override
  bool get readerOverrideLineSpacing => overrides.lineSpacing != null || super.readerOverrideLineSpacing;
  @override
  bool get readerOverrideAlignment => overrides.alignment != null || super.readerOverrideAlignment;
}
