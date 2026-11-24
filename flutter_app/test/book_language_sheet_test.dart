import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/book_language_corrections.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/narration_plan.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/services/conversion/embedded_conversion_contract.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The book's language sheet: what Rust detected, a line when the file contradicts the text, and
/// the languages to choose from (the book's own first).
class _Converter extends UnavailableEmbeddedConverter implements NarrationPlanCapable {
  @override
  bool get supportsNarrationPlan => true;

  @override
  Future<BookLanguageAnalysis> bookLanguage(String path) async => BookLanguageAnalysis.fromJson({
    'declared': 'en',
    'confirmed': 'pt',
    'languages': ['fr', 'pt'],
    'profile': {
      'class': 'bilingual',
      'primary': 'pt',
      'languages': [
        {'language': 'pt', 'chars': 9000, 'fraction': 0.9, 'longest_section_chars': 9000, 'role': 'main'},
        {'language': 'fr', 'chars': 1000, 'fraction': 0.1, 'longest_section_chars': 1600, 'role': 'significant'},
      ],
      'incidental': [],
    },
  });

  @override
  Future<NarrationPlan> bookNarrationPlan(NarrationPlanRequest request) async => const NarrationPlan(
    decision: NarrationDecision(
      language: 'pt',
      source: NarrationDecisionSource.profile,
      declaredConflict: 'en',
    ),
  );

  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'de', modelCount: 1),
    TtsCatalogLanguage(tag: 'fr', modelCount: 1),
    TtsCatalogLanguage(tag: 'pt', modelCount: 3),
  ];
}

Future<SharedPreferences> _pump(WidgetTester tester, Locale locale) async {
  final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('lang-sheet-'));
  addTearDown(() => dir!.deleteSync(recursive: true));
  final file = File('${dir!.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
  final book = BookEntity(
    id: 'sheet-1',
    title: 'Dom Casmurro',
    author: 'Machado',
    filePath: file.path,
    displayFilename: 'book.epub',
    addedAt: DateTime(2025, 1, 1),
  );
  SharedPreferences.setMockInitialValues({'library.books.v1': '[${book.encode()}]'});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(_Converter()),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.longPress(find.text('Dom Casmurro'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Book language'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the sheet says what was detected and when the file contradicts the text', (tester) async {
    await _pump(tester, const Locale('en'));
    await _openSheet(tester);
    expect(find.byKey(const ValueKey('book-language-summary')), findsOneWidget);
    expect(find.text('Português 90%'), findsOneWidget);
    expect(find.text('Also written in Français'), findsOneWidget);
    expect(
      find.text('The file says English; the text is Português.'),
      findsOneWidget,
      reason: 'reported, never an alert',
    );
    // The book's own languages come first, then the catalog.
    expect(find.text('In this book'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-language-pt')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-language-de')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('book-language-pt'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('book-language-de'))).dy),
    );
  });

  testWidgets('choosing a language stores the correction and Automatic clears it', (tester) async {
    final prefs = await _pump(tester, const Locale('en'));
    await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('book-language-fr')).first);
    await tester.pumpAndSettle();
    expect(BookLanguageCorrections(prefs).decision('sheet-1').bookLanguage, 'fr');

    await _openSheet(tester);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the current choice is marked');
    await tester.tap(find.byKey(const ValueKey('book-language-')));
    await tester.pumpAndSettle();
    expect(BookLanguageCorrections(prefs).decision('sheet-1').bookLanguage, isNull);
  });

  testWidgets('the sheet is localized in Portuguese', (tester) async {
    await _pump(tester, const Locale('pt'));
    await tester.longPress(find.text('Dom Casmurro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Idioma do livro'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Também escrito em Français'), findsOneWidget);
    expect(find.text('O arquivo diz English; o texto está em Português.'), findsOneWidget);
    expect(find.text('Neste livro'), findsOneWidget);
  });
}
