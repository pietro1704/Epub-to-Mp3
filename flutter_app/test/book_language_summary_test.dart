import 'package:flutter_app/models/book_language_summary.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_test/flutter_test.dart';

BookLanguageAnalysis _analysis(Map<String, dynamic> profile, {String? confirmed, String? declared}) =>
    BookLanguageAnalysis.fromJson({
      'declared': declared,
      'confirmed': confirmed,
      'languages': ['fr', 'la', 'pt'],
      'profile': profile,
    });

Map<String, dynamic> _share(String language, double fraction, String role) => {
  'language': language,
  'chars': (fraction * 10000).round(),
  'fraction': fraction,
  'longest_section_chars': 100,
  'role': role,
};

void main() {
  test('the main language with its share, then the languages written and the languages only quoted', () {
    final summary = BookLanguageSummary.from(
      _analysis({
        'class': 'bilingual',
        'primary': 'pt',
        'languages': [
          _share('pt', 0.9, 'main'),
          _share('fr', 0.08, 'significant'),
          _share('de', 0.01, 'section'),
          _share('la', 0.01, 'incidental'),
        ],
        'incidental': [],
      }),
    );
    expect(summary.main, 'pt');
    expect(summary.mainPercent, 90);
    expect(summary.alsoWritten, ['fr', 'de'], reason: 'significant and section languages');
    expect(summary.alsoQuoted, ['la'], reason: 'incidental ones are quotations');
  });

  test('without a profile the confirmed language is the whole summary', () {
    final summary = BookLanguageSummary.from(
      BookLanguageAnalysis.fromJson({'confirmed': 'en', 'languages': ['en']}),
    );
    expect(summary.main, 'en');
    expect(summary.mainPercent, isNull);
    expect(summary.alsoWritten, isEmpty);
    expect(summary.alsoQuoted, isEmpty);
  });

  test('the role of a share is read and an unknown one does not break the decode', () {
    final analysis = _analysis({
      'class': 'multilingual',
      'primary': 'pt',
      'languages': [_share('pt', 0.9, 'main'), _share('xx', 0.1, 'a_future_role')],
      'incidental': [],
    });
    expect(analysis.profile!.languages.first.role, BookLanguageRole.main);
    expect(analysis.profile!.languages.last.role, BookLanguageRole.unknown);
  });
}
