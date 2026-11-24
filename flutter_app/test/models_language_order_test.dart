import 'dart:ui' show Locale;

import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/language_order.dart';
import 'package:flutter_test/flutter_test.dart';

TtsCatalogLanguage _language(String tag, {int? rank}) =>
    TtsCatalogLanguage(tag: tag, modelCount: 1, popularityRank: rank);

List<String> _tags(List<TtsCatalogLanguage> languages) => [
  for (final language in languages) language.tag,
];

void main() {
  final catalog = [
    _language('cy'),
    _language('de', rank: 5),
    _language('en', rank: 1),
    _language('es', rank: 2),
    _language('fr', rank: 4),
    _language('is'),
    _language('pt', rank: 3),
    _language('sq'),
  ];

  test('system languages come first, in the system order', () {
    final ordered = orderModelLanguages(catalog, const [
      Locale('pt', 'BR'),
      Locale('en', 'US'),
      Locale('de'),
    ]);
    expect(_tags(ordered.system), ['pt', 'en', 'de']);
  });

  test(
    'then the most popular languages by rank, then the rest alphabetically',
    () {
      final ordered = orderModelLanguages(catalog, const [Locale('pt', 'BR')]);
      expect(_tags(ordered.system), ['pt']);
      expect(_tags(ordered.popular), ['en', 'es', 'fr', 'de']);
      // Alphabetical by the name shown (endonym): Cymraeg, Íslenska, Shqip.
      expect(_tags(ordered.others), ['cy', 'is', 'sq']);
      expect(_tags(ordered.all), [
        'pt',
        'en',
        'es',
        'fr',
        'de',
        'cy',
        'is',
        'sq',
      ]);
    },
  );

  test('a language is listed once, and system languages the catalog lacks are ignored', () {
    final ordered = orderModelLanguages(catalog, const [
      Locale('pt', 'PT'),
      Locale('pt', 'BR'),
      Locale('xx'),
      Locale('en'),
    ]);
    expect(_tags(ordered.system), ['pt', 'en']);
    expect(_tags(ordered.all).toSet().length, catalog.length);
    expect(_tags(ordered.all).length, catalog.length);
  });

  test('without system locales or ranks everything is alphabetical', () {
    final ordered = orderModelLanguages([
      _language('sq'),
      _language('cy'),
    ], const []);
    expect(ordered.system, isEmpty);
    expect(ordered.popular, isEmpty);
    expect(_tags(ordered.others), ['cy', 'sq']);
  });

  test('the catalog JSON carries the shared popularity rank', () {
    final parsed = TtsCatalogLanguage.parseAll(
      '{"schema_version":1,"languages":[{"tag":"en","model_count":3,"popularity_rank":1},{"tag":"cy","model_count":1}]}',
    );
    expect(parsed[0].popularityRank, 1);
    expect(parsed[1].popularityRank, isNull);
  });
}
