import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filter controls preserve tag identity and clear only the selected tag', (tester) async {
    String? selectedTag = 'Latin 1';
    final selections = <String?>[];
    final searches = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => LibraryFilterControls(
              searchQuery: 'book',
              selectedTag: selectedTag,
              allTags: const ['Latin 1', 'Latin 2'],
              onSearchChanged: searches.add,
              onTagChanged: (value) {
                selections.add(value);
                update(() => selectedTag = value);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Latin 2'));
    await tester.pump();
    expect(selections, ['Latin 2']);
    await tester.tap(find.text('Latin 2'));
    await tester.pump();
    expect(selections, ['Latin 2', null]);
    await tester.tap(find.byIcon(Icons.clear));
    expect(searches, ['']);
    expect(selections, ['Latin 2', null]);
  });
}
