import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/root_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RootScreen(),
    ),
  );
}

void main() {
  group('RootScreen', () {
    testWidgets('has 3 navigation destinations', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      expect(find.byType(NavigationDestination), findsNWidgets(3));
      // "Reader" appears both in the nav bar label and the AppBar title,
      // so we check at least one. Same for "Library" vs library tab content.
      expect(find.text('Reader'), findsWidgets);
      expect(find.text('Library'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);
    });

    testWidgets('reader tab is shown by default (index 0)', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      // Reader tab empty state text
      expect(find.text('Pick a book to read'), findsOneWidget);
    });

    testWidgets('tapping Library navigates to library tab', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      await t.tap(find.text('Library'));
      await t.pumpAndSettle();

      // Library screen empty state
      expect(find.text('No books yet'), findsOneWidget);
    });

    testWidgets('tapping Settings navigates to settings tab', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();

      expect(find.text('Backend URL'), findsOneWidget);
    });
  });
}
