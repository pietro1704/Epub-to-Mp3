// Regression: page-turn (advancePage / retreatPage) must fire
// `onAutoHideChrome` so the host screen can dim AppBar + player bar +
// status bar for an immersive reading experience. Mirrors the iOS
// PlayerReaderView page-turn dim parity.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';

FulltextChapter _chapter() => FulltextChapter.fromJson({
      'index': 0,
      'name': 'Chapter 1',
      'text': 'One sentence. Another sentence.',
    });

List<SentenceSpan> _spans() => _chapter().splitSentences();

Widget _wrap(SharedPreferences prefs, Widget child) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SizedBox(
        width: 400,
        height: 800,
        child: Scaffold(body: child),
      ),
    ),
  );
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

void main() {
  group('ReaderView onAutoHideChrome', () {
    testWidgets('advancePage fires onAutoHideChrome', (t) async {
      final prefs = await _prefs();
      var fired = 0;
      final key = GlobalKey<State<ReaderView>>();
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: key,
          chapter: _chapter(),
          spans: _spans(),
          onAutoHideChrome: () => fired++,
        ),
      ));
      await t.pump();

      // ignore: invalid_use_of_protected_member
      (key.currentState as dynamic).advancePage();
      await t.pump();

      expect(fired, greaterThanOrEqualTo(1),
          reason:
              'page-turn must signal the host so chrome dims for immersion');
    });

    testWidgets('retreatPage fires onAutoHideChrome', (t) async {
      final prefs = await _prefs();
      var fired = 0;
      final key = GlobalKey<State<ReaderView>>();
      await t.pumpWidget(_wrap(
        prefs,
        ReaderView(
          key: key,
          chapter: _chapter(),
          spans: _spans(),
          onAutoHideChrome: () => fired++,
        ),
      ));
      await t.pump();

      // ignore: invalid_use_of_protected_member
      (key.currentState as dynamic).retreatPage();
      await t.pump();

      expect(fired, greaterThanOrEqualTo(1));
    });
  });
}
