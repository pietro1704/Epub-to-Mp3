import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Apple #1429: the user chooses how many columns the library shows (1..8);
/// the choice is remembered and capped only by what fits (72 pt tiles, as Apple).
Future<SharedPreferences> _pump(
  WidgetTester tester, {
  Map<String, Object> extra = const {},
  Locale locale = const Locale('en'),
}) async {
  final books = List.generate(
    6,
    (i) => BookEntity(
      id: 'col-$i',
      title: 'Book $i',
      author: 'Author',
      filePath: '/tmp/col-$i.epub',
      displayFilename: 'col-$i.epub',
      addedAt: DateTime(2025, 1, 6 - i),
    ),
  );
  SharedPreferences.setMockInitialValues({
    'library.books.v1': '[${books.map((b) => b.encode()).join(',')}]',
    ...extra,
  });
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

int _columnsOnFirstRow(WidgetTester tester) {
  final cards = find.descendant(
    of: find.byType(GridView),
    matching: find.byType(Card),
  );
  final first = tester.getRect(cards.first).top;
  var count = 0;
  for (var i = 0; i < cards.evaluate().length; i++) {
    if ((tester.getRect(cards.at(i)).top - first).abs() < 0.5) count++;
  }
  return count;
}

void main() {
  testWidgets('choosing 3 columns on a phone shows 3 and is remembered', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    final prefs = await _pump(tester);
    expect(_columnsOnFirstRow(tester), 2, reason: 'phone default');

    await tester.tap(find.byTooltip('Columns'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();

    expect(_columnsOnFirstRow(tester), 3);
    expect(prefs.getInt('library.requestedColumns.v1'), 3);
  });

  testWidgets('1 column is honored and 8 is capped by what fits', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    await _pump(tester, extra: {'library.requestedColumns.v1': 1});
    expect(_columnsOnFirstRow(tester), 1);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, extra: {'library.requestedColumns.v1': 8});
    // (390 - 32 + 16) / (72 + 16) = 4.25 -> 4 tiles of >= 72 fit.
    expect(_columnsOnFirstRow(tester), 4);
  });

  testWidgets('the requested count returns when the width allows it again', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    await _pump(tester, extra: {'library.requestedColumns.v1': 4});
    expect(_columnsOnFirstRow(tester), 4);
    await tester.binding.setSurfaceSize(const Size(320, 1200));
    await tester.pumpAndSettle();
    // (320 - 32 + 16) / 88 = 3.45 -> only 3 fit.
    expect(_columnsOnFirstRow(tester), 3);
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    await tester.pumpAndSettle();
    expect(_columnsOnFirstRow(tester), 4);
  });
}
