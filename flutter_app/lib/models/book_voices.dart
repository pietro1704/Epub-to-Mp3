import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tts_preferences.dart';

/// The voice the listener chose for one book (the reader's voice picker). A book without one is
/// narrated with the voice of its language, like its reading speed follows the default. Stored
/// like a per-book preference: `bookId` to the same selection JSON as the language choices.
class BookVoices {
  BookVoices(this._prefs);

  static const preferenceKey = 'book.voices.v1';

  final SharedPreferences _prefs;

  Map<String, dynamic> _all() {
    try {
      final decoded = jsonDecode(_prefs.getString(preferenceKey) ?? '{}');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  TtsSelection? voiceFor(String bookId) {
    final entry = _all()[bookId];
    if (entry is! Map) return null;
    try {
      return TtsSelection.fromJson(Map<String, dynamic>.from(entry));
    } on Object {
      return null;
    }
  }

  Future<void> set(String bookId, TtsSelection selection) =>
      _prefs.setString(preferenceKey, jsonEncode({..._all(), bookId: selection.toJson()}));

  Future<void> clear(String bookId) {
    final all = _all();
    if (all.remove(bookId) == null) return Future.value();
    return _prefs.setString(preferenceKey, jsonEncode(all));
  }
}
