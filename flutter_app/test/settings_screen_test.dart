import 'dart:convert';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester t, {
  Map<String, Object> prefsData = const {},
  Locale? locale,
}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: locale,
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
    testWidgets('fresh speech defaults choose Faber and offline native fallback', (t) async {
      await _pump(t);
      final saved = AppSettings(await SharedPreferences.getInstance()).ttsPreferences;
      expect(saved.primary.modelId, 'pt_BR-faber-medium');
      expect(saved.secondary!.engine, 'system');
      expect(saved.policyVersion, 2);
      expect(saved.allowOnlineFallback, false);
      expect(find.text('Faber medium · Offline'), findsOneWidget);
      expect(find.text('System voice · Offline fallback'), findsOneWidget);
    });

    testWidgets('existing no-fallback policy adopts new defaults only on action', (t) async {
      await _pump(t, prefsData: {
        'ttsPreferences': jsonEncode(const TtsPreferences().toJson()),
      });
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
    });

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
          prefsData: {'ttsPreferences': jsonEncode(preferences.toJson())},
        );
        expect(t.takeException(), isNull);
        expect(find.text('Edge · pt-BR-FranciscaNeural'), findsOneWidget);
        expect(find.text('Edge · Online'), findsOneWidget);
        final saved = AppSettings(
          await SharedPreferences.getInstance(),
        ).ttsPreferences;
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
          prefsData: {'ttsPreferences': jsonEncode(preferences.toJson())},
        );
        await t.tap(find.text('Faber medium · Offline'));
        await t.pumpAndSettle();
        await t.tap(find.text('Edge · Online').last);
        await t.pumpAndSettle();
        final saved = AppSettings(
          await SharedPreferences.getInstance(),
        ).ttsPreferences;
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
        'Narração principal',
        'Narração secundária',
        'Permitir voz secundária online',
      ),
      (
        'es',
        'Narración principal',
        'Narración secundaria',
        'Permitir voz secundaria en línea',
      ),
    ]) {
      testWidgets('new narration controls use ${item.$1} localization', (
        t,
      ) async {
        await _pump(t, locale: Locale(item.$1));
        expect(find.text(item.$2), findsOneWidget);
        expect(find.text(item.$3), findsOneWidget);
        expect(find.text(item.$4), findsOneWidget);
        expect(find.text('Primary narration'), findsNothing);
      });
    }

    testWidgets('online secondary requires consent and revocation clears it', (
      t,
    ) async {
      await _pump(t);
      await t.scrollUntilVisible(
        find.text('Allow online secondary'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        t.element(find.text('Allow online secondary')),
        alignment: 0.5,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Allow online secondary'));
      await t.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(AppSettings(prefs).ttsPreferences.allowOnlineFallback, true);
      await t.scrollUntilVisible(
        find.text('System voice · Offline fallback'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        t.element(find.text('System voice · Offline fallback')),
        alignment: 0.5,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('System voice · Offline fallback'));
      await t.pumpAndSettle();
      await t.tap(find.text('Edge · Online').last);
      await t.pumpAndSettle();
      expect(AppSettings(prefs).ttsPreferences.secondary!.engine, 'edge');
      await t.scrollUntilVisible(
        find.text('Allow online secondary'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        t.element(find.text('Allow online secondary')),
        alignment: 0.5,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Allow online secondary'));
      await t.pumpAndSettle();
      expect(AppSettings(prefs).ttsPreferences.allowOnlineFallback, false);
      expect(AppSettings(prefs).ttsPreferences.secondary, isNull);
    });

    testWidgets('shows top section headers', (t) async {
      await _pump(t);

      expect(find.text('Audio engine'), findsOneWidget);
      expect(find.text('Remote backend'), findsOneWidget);
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

    testWidgets('primary and secondary narration controls exist', (t) async {
      await _pump(t);

      expect(find.text('Primary narration'), findsOneWidget);
      expect(find.text('Secondary narration'), findsOneWidget);
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
