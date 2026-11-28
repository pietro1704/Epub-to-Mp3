// Parity with the Apple fix (#1797): the paginated layout turns pages, so desktop
// must not show a scroll bar over the page.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

void main() {
  testWidgets('paginated desktop reader shows no scroll bar', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({
      'readerLayout': ReaderLayout.paginated.rawValue,
    });
    final prefs = await SharedPreferences.getInstance();
    await t.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ReaderView(
              chapter: FulltextChapter(
                index: 1,
                name: 'Chapter 1',
                text: 'First sentence here. Second sentence here. Third one.',
              ),
              spans: const [],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final found = find.byType(Scrollbar).evaluate().length;
    debugDefaultTargetPlatformOverride = null;
    expect(found, 0);
  });
}
