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

/// Opens a narration row, then chooses an engine that has a single voice.
Future<void> _pickEngine(WidgetTester t, String rowKey, String engine) async {
  final row = find.byKey(ValueKey(rowKey));
  await t.scrollUntilVisible(row, -150, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(t.element(row), alignment: 0.5);
  await t.pumpAndSettle();
  await t.tap(find.descendant(of: row, matching: find.byType(ListTile)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey('narration-engine-$engine')));
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

    testWidgets('saved Piper Low choices never return to the picker', (t) async {
      const preferences = TtsPreferences(
        primary: TtsSelection(engine: 'piper', modelId: 'pt_BR-edresson-low'),
        secondary: TtsSelection(engine: 'piper', modelId: 'en_US-lessac-low'),
      );
      final saved = jsonEncode(preferences.toJson());
      await _pump(t, models: true, prefsData: {'ttsPreferences': saved});

      expect(find.text('Book language'), findsOneWidget);
      expect(find.textContaining('-low'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      final effective = AppSettings(prefs).ttsPreferences;
      expect(effective.primary, TtsSelection.automaticPiper);
      expect(effective.secondary, isNull);
      expect(effective.allowOnlineFallback, isFalse);
      expect(prefs.getString('ttsPreferences'), saved);
    });

    testWidgets('reset activates Piper selection by book language', (t) async {
      final catalog = TtsCatalog.decode(jsonEncode({
        'schema_version': 3,
        'entries': [],
        'providers': [],
        'default_selection': {
          'version': 2,
          'provider': 'piper',
          'runtime': 'piper',
          'model_id': 'fixture-model',
          'model_revision': 'fixture-revision',
        },
      }));
      await _pump(
        t,
        models: true,
        catalog: catalog,
        prefsData: {
          'ttsPreferences': jsonEncode(const TtsPreferences().toJson()),
        },
      );
      final settings = AppSettings(await SharedPreferences.getInstance());
      expect(settings.ttsPreferences.primary.modelId, TtsSelection.faber.modelId);
      expect(settings.ttsPreferences.secondary, isNull);

      final reset = find.byKey(const ValueKey('tts-use-recommended-defaults'));
      await t.scrollUntilVisible(reset, 150, scrollable: find.byType(Scrollable).first);
      await t.tap(reset);
      await t.pumpAndSettle();

      final saved = settings.ttsPreferences;
      expect(saved.primary.modelId, 'piper-auto');
      expect(saved.primary.session, isNull);
      expect(saved.secondary?.engine, 'system');
      expect(saved.allowOnlineFallback, isFalse);
    });

    testWidgets(
      'fresh speech defaults choose Piper by book language with offline fallback',
      (t) async {
        await _pump(t, models: true);
        final saved = AppSettings(await SharedPreferences.getInstance())
            .ttsPreferences;
        expect(saved.primary.modelId, 'piper-auto');
        expect(saved.secondary!.engine, 'system');
        expect(saved.policyVersion, 2);
        expect(saved.allowOnlineFallback, false);
        expect(find.text('Book language'), findsOneWidget);
        expect(find.text('Installed system voice'), findsOneWidget);
      },
    );

    testWidgets(
      'existing no-fallback policy adopts new defaults only on action',
      (t) async {
        await _pump(
          t,
          models: true,
          prefsData: {
            'ttsPreferences': jsonEncode(const TtsPreferences().toJson()),
          },
        );
        final settings = AppSettings(await SharedPreferences.getInstance());
        expect(settings.ttsPreferences.secondary, isNull);
        await t.scrollUntilVisible(
          find.byKey(const ValueKey('tts-use-recommended-defaults')),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await t.tap(find.byKey(const ValueKey('tts-use-recommended-defaults')));
        await t.pumpAndSettle();
        expect(settings.ttsPreferences.primary.engine, 'piper');
        expect(settings.ttsPreferences.secondary!.engine, 'system');
        expect(settings.ttsPreferences.policyVersion, 2);
      },
    );

    testWidgets(
      'valid same-engine voices remain distinct settings selections',
      (t) async {
        const preferences = TtsPreferences(
          primary: TtsSelection(engine: 'edge', voice: 'pt-BR-FranciscaNeural'),
          secondary: TtsSelection.edge,
          allowOnlineFallback: true,
        );
        await _pump(
          t,
          models: true,
          prefsData: {'ttsPreferences': jsonEncode(preferences.toJson())},
        );
        expect(t.takeException(), isNull);
        expect(find.text('pt-BR-FranciscaNeural'), findsOneWidget);
        expect(find.text('Online speech'), findsOneWidget);
        final saved = AppSettings(await SharedPreferences.getInstance())
            .ttsPreferences;
        expect(saved.primary.voice, 'pt-BR-FranciscaNeural');
        expect(saved.secondary!.voice, isNull);
        expect(saved.allowOnlineFallback, true);
      },
    );

    testWidgets(
      'changing primary preserves a different secondary voice on the same engine',
      (t) async {
        const preferences = TtsPreferences(
          secondary: TtsSelection(
            engine: 'edge',
            voice: 'pt-BR-FranciscaNeural',
          ),
          allowOnlineFallback: true,
        );
        await _pump(
          t,
          models: true,
          prefsData: {'ttsPreferences': jsonEncode(preferences.toJson())},
        );
        await _pickEngine(t, 'narration-primary-row', 'edge');
        final saved = AppSettings(await SharedPreferences.getInstance())
            .ttsPreferences;
        expect(saved.primary.engine, 'edge');
        expect(saved.primary.voice, isNull);
        expect(saved.secondary!.voice, 'pt-BR-FranciscaNeural');
        expect(saved.allowOnlineFallback, true);
        expect(t.takeException(), isNull);
      },
    );

    for (final item in [
      (
        'pt',
        'Modelo de voz',
        'Voz secundária',
        'Permitir reserva online',
      ),
      (
        'es',
        'Narración principal',
        'Narración secundaria',
        'Permitir respaldo en línea',
      ),
    ]) {
      testWidgets('new narration controls use ${item.$1} localization', (
        t,
      ) async {
        await _pump(t, models: true, locale: Locale(item.$1));
        expect(find.text(item.$2), findsOneWidget);
        expect(find.text(item.$3), findsOneWidget);
        expect(find.text(item.$4), findsOneWidget);
        expect(find.text('Primary narration'), findsNothing);
      });
    }

    testWidgets('online secondary requires consent and revocation clears it', (
      t,
    ) async {
      await _pump(t, models: true);
      await t.scrollUntilVisible(
        find.text('Allow online fallback'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        t.element(find.text('Allow online fallback')),
        alignment: 0.5,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Allow online fallback'));
      await t.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(AppSettings(prefs).ttsPreferences.allowOnlineFallback, true);
      await _pickEngine(t, 'narration-secondary-row', 'edge');
      expect(AppSettings(prefs).ttsPreferences.secondary!.engine, 'edge');
      await t.scrollUntilVisible(
        find.text('Allow online fallback'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        t.element(find.text('Allow online fallback')),
        alignment: 0.5,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Allow online fallback'));
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

    testWidgets('the Models screen hosts the primary and secondary narration controls', (t) async {
      await _pump(t, models: true);
      expect(find.text('Audio engine'), findsOneWidget);

      expect(find.text('Voice engine'), findsOneWidget);
      expect(find.text('Secondary voice'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('reader section has font and theme controls', (t) async {
      await _pump(t);

      await t.scrollUntilVisible(
        find.text('Reader font size'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Reader font size'), findsOneWidget);
      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
    });

    testWidgets('reader section has layout and spacing', (t) async {
      await _pump(t);

      await t.scrollUntilVisible(
        find.text('Layout'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Layout'), findsOneWidget);
      expect(find.text('Line spacing'), findsOneWidget);
    });

    testWidgets('font size stepper shows n of 5', (t) async {
      await _pump(t, prefsData: {'readerFontSize': 2});

      await t.scrollUntilVisible(
        find.text('3 of 5'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('3 of 5'), findsOneWidget);
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
