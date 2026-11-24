import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester t, {
  Map<String, Object> prefsData = const {},
  Locale? locale,
  TtsCatalog? catalog,
  bool models = false,
}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        if (catalog != null) ttsCatalogProvider.overrideWith((ref) => catalog),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: models ? const ModelsScreen() : const SettingsScreen(),
      ),
    ),
  );
  await t.pumpAndSettle();
}


void main() {
  group('SettingsScreen M3', () {
    const desktopHosts = {
      TargetPlatform.linux: 'Linux',
      TargetPlatform.windows: 'Windows',
    };
    testWidgets(
      'labels the desktop host in About',
      (t) async {
        await _pump(t);
        await t.scrollUntilVisible(find.text('Platform'), 250);
        expect(find.text(desktopHosts[defaultTargetPlatform]!), findsOneWidget);
      },
      variant: TargetPlatformVariant(desktopHosts.keys.toSet()),
    );







    for (final item in [
      ('pt', 'Vozes de reserva', 'Permitir reserva online'),
      ('es', 'Voces de reserva', 'Permitir respaldo en línea'),
    ]) {
      testWidgets('the fallback controls use ${item.$1} localization', (t) async {
        await _pump(t, models: true, locale: Locale(item.$1));
        expect(find.text(item.$2), findsOneWidget);
        expect(find.text(item.$3), findsOneWidget);
        expect(find.text('Fallback voices'), findsNothing);
      });
    }

    testWidgets('the online fallback needs the user to turn it on, and turning it off clears an Edge reserve', (t) async {
      await _pump(
        t,
        models: true,
        prefsData: {
          'ttsPreferences': jsonEncode(const TtsPreferences(
            primary: TtsSelection.automaticPiper,
            secondary: TtsSelection.edge,
            allowOnlineFallback: true,
          ).toJson()),
        },
      );
      final prefs = await SharedPreferences.getInstance();
      expect(AppSettings(prefs).ttsPreferences.allowOnlineFallback, true);
      final online = find.text('Allow online fallback');
      await t.scrollUntilVisible(online, 150, scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(online);
      await t.pumpAndSettle();
      await t.tap(online);
      await t.pumpAndSettle();
      expect(AppSettings(prefs).ttsPreferences.allowOnlineFallback, false);
      expect(AppSettings(prefs).ttsPreferences.secondary, isNull);
    });


    testWidgets('shows top section headers', (t) async {
      await _pump(t);

      expect(find.text('Remote backend'), findsNothing);
      await t.scrollUntilVisible(
        find.text('Reader'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Reader'), findsOneWidget);
    });

    testWidgets('playback section visible after scroll', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(
        find.text('Playback'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();

      expect(find.text('Playback'), findsOneWidget);
    });

    testWidgets('about section visible after scroll', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(
        find.text('About'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();

      expect(find.text('About'), findsOneWidget);
      expect(find.text('Platform'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
    });

    testWidgets('settings keeps a single Models row, no voice dropdowns', (t) async {
      await _pump(t);

      expect(find.byKey(const ValueKey('settings-models-row')), findsOneWidget);
      expect(find.text('Voice engine'), findsNothing);
      expect(find.text('Secondary voice'), findsNothing);
    });


    testWidgets('reader section is one row that opens the reading preferences (default for all books)', (t) async {
      await _pump(t);
      final row = find.byKey(const ValueKey('settings-reading-preferences-row'));
      await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: row, matching: find.text('Default for all books')), findsOneWidget);
      // The appearance controls no longer repeat inline.
      expect(find.text('Line spacing'), findsNothing);
      await t.tap(row);
      await t.pumpAndSettle();
      expect(find.text('Reading preferences'), findsWidgets);
      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Layout'), findsOneWidget);
      expect(find.text('Line spacing'), findsOneWidget);
    });

    testWidgets('auto-scroll toggle present', (t) async {
      await _pump(t);
      await t.scrollUntilVisible(
        find.text('Auto-scroll'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('Auto-scroll'), findsOneWidget);
    });
  });
}
