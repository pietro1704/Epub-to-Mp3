import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _pump(WidgetTester tester, {TtsPreferences? saved}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (saved != null) await AppSettings(prefs).setTtsPreferences(saved);
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SingleChildScrollView(child: VoiceSelectionSettings())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

void main() {
  const toggle = ValueKey('tts-automatic-system-fallback');

  testWidgets('the automatic system voice fallback is on by default', (tester) async {
    final prefs = await _pump(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isTrue);
    expect(AppSettings(prefs).ttsPreferences.allowAutomaticSystemFallback, isTrue);
  });

  testWidgets('turning it off stores policy 3 and keeps the chosen voices; turning it on restores policy 2', (tester) async {
    final prefs = await _pump(tester);
    final before = AppSettings(prefs).ttsPreferences;
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    final off = AppSettings(prefs).ttsPreferences;
    expect(off.policyVersion, 3);
    expect(off.allowAutomaticSystemFallback, isFalse);
    expect(off.primary.toJson(), before.primary.toJson());
    expect(off.secondary?.toJson(), before.secondary?.toJson());
    expect(off.allowOnlineFallback, before.allowOnlineFallback);
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);

    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.policyVersion, 2);
  });

  testWidgets('a saved "no automatic system voice" policy survives unrelated changes', (tester) async {
    final prefs = await _pump(
      tester,
      saved: const TtsPreferences(primary: TtsSelection.faber, secondary: TtsSelection.system, policyVersion: 3),
    );
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Allow online fallback'));
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.policyVersion, 3);
  });
}
