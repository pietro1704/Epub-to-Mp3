import 'dart:ui' show Locale;

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'language_model_choices.dart';
import 'language_model_resolution.dart';
import 'language_names.dart';

/// The Models screen languages in their three groups (card MODELS-LANGUAGE-SUBSCREEN).
class OrderedModelLanguages {
  const OrderedModelLanguages({
    required this.system,
    required this.popular,
    required this.others,
  });

  /// Languages of the system, in the system's own order.
  final List<TtsCatalogLanguage> system;

  /// The most popular of the rest (the rank is Rust's shared list), most popular first.
  final List<TtsCatalogLanguage> popular;

  /// Every other language, alphabetically by the name shown.
  final List<TtsCatalogLanguage> others;

  List<TtsCatalogLanguage> get all => [...system, ...popular, ...others];
}

/// Orders [catalog] for the Models language screen: (1) the system languages in system order
/// (Android `LocaleList`; the user's locales on Windows/Linux), (2) the most popular languages by
/// their shared rank, (3) the rest alphabetically. A language is listed once; system languages
/// the catalog does not have are ignored.
OrderedModelLanguages orderModelLanguages(
  List<TtsCatalogLanguage> catalog,
  List<Locale> systemLocales,
) {
  final byBase = {
    for (final language in catalog)
      LanguageModelChoices.baseLanguage(language.tag): language,
  };
  final system = <TtsCatalogLanguage>[];
  for (final locale in systemLocales) {
    final language = byBase.remove(
      LanguageModelChoices.baseLanguage(locale.languageCode),
    );
    if (language != null) system.add(language);
  }
  final rest = byBase.values.toList();
  final popular =
      rest.where((language) => language.popularityRank != null).toList()
        ..sort((a, b) => a.popularityRank!.compareTo(b.popularityRank!));
  final others =
      rest.where((language) => language.popularityRank == null).toList()..sort(
        (a, b) =>
            _sortKey(languageEndonym(a.tag))
                .compareTo(_sortKey(languageEndonym(b.tag))),
      );
  return OrderedModelLanguages(
    system: system,
    popular: popular,
    others: others,
  );
}

/// Lower case without Latin diacritics, so "Íslenska" sorts with the I words.
String _sortKey(String name) {
  const from = 'àáâãäåçèéêëìíîïñòóôõöøùúûüýÿāćčďēěłńňřśšťůźżž';
  const to = 'aaaaaaceeeeiiiinoooooouuuuyyaccdeelnnrsstuzzz';
  final buffer = StringBuffer();
  for (final rune in name.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    final index = from.indexOf(character);
    buffer.write(index < 0 ? character : to[index]);
  }
  return buffer.toString();
}

/// The user's languages in the system's order: Android's `LocaleList`, the user's locales on
/// Windows and Linux. Overridden in tests.
final systemLocalesProvider = Provider<List<Locale>>(
  (ref) => WidgetsBinding.instance.platformDispatcher.locales,
);
