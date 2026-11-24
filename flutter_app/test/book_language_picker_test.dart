import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/book_language_corrections.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Apple "Book language": a library book can be given a language by the user,
/// or returned to automatic detection, from its actions.
Future<SharedPreferences> _pump(WidgetTester tester, Locale locale) async {
  final book = BookEntity(
    id: 'lang-1',
    title: 'Dom Casmurro',
    author: 'Machado',
    filePath: '/tmp/lang-1.epub',
    displayFilename: 'lang-1.epub',
    addedAt: DateTime(2025, 1, 1),
  );
  SharedPreferences.setMockInitialValues({'library.books.v1': '[${book.encode()}]'});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
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

void main() {
  testWidgets('the book actions let the user set and clear the book language', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    final prefs = await _pump(tester, const Locale('en'));
    await tester.longPress(find.text('Dom Casmurro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book language'));
    await tester.pumpAndSettle();
    expect(find.text('Automatic detection'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Português (Brasil)'),
      200,
      scrollable: find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Português (Brasil)'));
    await tester.pumpAndSettle();
    expect(BookLanguageCorrections(prefs).decision('lang-1').bookLanguage, 'pt-BR');

    await tester.longPress(find.text('Dom Casmurro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book language'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Português (Brasil)'),
      200,
      scrollable: find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the current choice is marked');
    await tester.scrollUntilVisible(
      find.text('Automatic detection'),
      -200,
      scrollable: find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Automatic detection'));
    await tester.pumpAndSettle();
    expect(BookLanguageCorrections(prefs).decision('lang-1').bookLanguage, isNull);
  });

  testWidgets('the entry and the dialog are localized in Portuguese', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    await _pump(tester, const Locale('pt'));
    await tester.longPress(find.text('Dom Casmurro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Idioma do livro'));
    await tester.pumpAndSettle();
    expect(find.text('Detecção automática'), findsOneWidget);
    expect(find.textContaining('Esta escolha vale para este livro ou trecho'), findsOneWidget);
  });
}
