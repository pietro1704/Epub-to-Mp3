import 'package:flutter_app/models/language_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The base languages of the real model catalog (converter_tts_catalog_languages_json_v1).
  const catalogLanguages = [
    'ar', 'bg', 'ca', 'cs', 'cy', 'da', 'de', 'el', 'en', 'es', 'eu', 'fa', 'fi', 'fr', 'hi', 'hu', 'hy', 'id',
    'is', 'it', 'ka', 'kk', 'ku', 'lb', 'lv', 'ml', 'nb', 'ne', 'nl', 'no', 'pl', 'pt', 'ro', 'ru', 'sk', 'sl',
    'sq', 'sr', 'sv', 'sw', 'te', 'tr', 'uk', 'ur', 'vi', 'zh',
  ];

  test('every catalog language is listed by its own name, never by its raw code (A8: "eu", "hy", "sq"…)', () {
    final raw = [for (final tag in catalogLanguages) if (languageEndonym(tag) == tag) tag];
    expect(raw, isEmpty);
  });
}
