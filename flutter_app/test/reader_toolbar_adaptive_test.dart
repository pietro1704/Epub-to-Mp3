import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

EbookFulltext _book() => EbookFulltext.fromJson({
  'jobId': 'b',
  'bookTitle': 'Sample',
  'chapters': [
    for (var i = 0; i < 2; i++)
      {'index': i, 'name': 'Chapter $i', 'text': 'Text $i.'},
  ],
});

Future<void> _pump(WidgetTester t, Size size) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: InstantReaderView(
            fulltext: _book(),
            bookId: 'b',
            onListenFrom: (_) async {},
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Finder _barTools() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('reader-tool-'),
);

void main() {
  testWidgets('a phone keeps one tool beside More', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pump(t, const Size(400, 800));
    expect(find.byKey(const ValueKey('reader-recent-tool')), findsOneWidget);
    expect(_barTools(), findsNothing);
    expect(find.byKey(const ValueKey('reader-overflow-menu')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an Android tablet shows every tool in the bar', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pump(t, const Size(1200, 800));
    expect(find.byKey(const ValueKey('reader-recent-tool')), findsNothing);
    expect(_barTools(), findsNWidgets(6));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a narrow desktop window moves the excess tools into More', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await _pump(t, const Size(1200, 800));
    final wide = _barTools().evaluate().length;
    await _pump(t, const Size(420, 800));
    final narrow = _barTools().evaluate().length;
    expect(narrow, lessThan(wide));
    await t.tap(find.byKey(const ValueKey('reader-overflow-menu')));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-menu-add-bookmark')),
      findsOneWidget,
    );
    // Every tool is reachable: in the bar or in More.
    for (final name in [
      'appearance',
      'contents',
      'search',
      'bookmarks',
      'listen',
    ]) {
      final inBar = find
          .byKey(ValueKey('reader-tool-$name'))
          .evaluate()
          .isNotEmpty;
      final inMenu = find
          .byKey(ValueKey('reader-menu-$name'))
          .evaluate()
          .isNotEmpty;
      expect(inBar || inMenu, isTrue, reason: name);
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
