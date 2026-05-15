import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester t,
    {Map<String, Object> prefsData = const {}}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsScreen(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('SettingsScreen M3', () {
    testWidgets('shows top section headers', (t) async {
      await _pump(t);

      expect(find.text('Audio engine'), findsOneWidget);
      expect(find.text('Remote backend'), findsOneWidget);
      expect(find.text('Reader'), findsOneWidget);
    });

    testWidgets('playback section visible after scroll', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(find.text('Playback'), 200,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();

      expect(find.text('Playback'), findsOneWidget);
    });

    testWidgets('about section visible after scroll', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(find.text('About'), 200,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();

      expect(find.text('About'), findsOneWidget);
      expect(find.text('Platform'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
    });

    testWidgets('audio engine toggle exists', (t) async {
      await _pump(t);

      expect(find.text('Use built-in audio engine'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('reader section has font and theme controls', (t) async {
      await _pump(t);

      expect(find.text('Reader font size'), findsOneWidget);
      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
    });

    testWidgets('reader section has layout and spacing', (t) async {
      await _pump(t);

      expect(find.text('Layout'), findsOneWidget);
      expect(find.text('Line spacing'), findsOneWidget);
    });

    testWidgets('font size stepper shows n of 5', (t) async {
      await _pump(t, prefsData: {'readerFontSize': 2});

      expect(find.text('3 of 5'), findsOneWidget);
    });

    testWidgets('auto-scroll toggle present', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(find.text('Auto-scroll'), 200,
          scrollable: find.byType(Scrollable).first);

      expect(find.text('Auto-scroll'), findsOneWidget);
    });
  });
}
