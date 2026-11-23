import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester tester, {
  required TtsPreferences preferences,
}) async {
  SharedPreferences.setMockInitialValues({
    'ttsPreferences': jsonEncode(preferences.toJson()),
  });
  final prefs = await SharedPreferences.getInstance();
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
  await tester.tap(find.descendant(
    of: find.byKey(const ValueKey('narration-primary-row')),
    matching: find.byType(ListTile),
  ));
  await tester.pumpAndSettle();
}

bool _edgeOfferedAsPrimary(WidgetTester tester) {
  return tester
      .widget<ListTile>(find.byKey(const ValueKey('narration-engine-edge')))
      .enabled;
}

void main() {
  testWidgets('Edge is not offered as the primary voice without online consent', (tester) async {
    await _pump(tester, preferences: const TtsPreferences.appDefaults());
    expect(_edgeOfferedAsPrimary(tester), isFalse);
  });

  testWidgets('Edge becomes selectable once the user allows online speech', (tester) async {
    await _pump(
      tester,
      preferences: const TtsPreferences(
        primary: TtsSelection.faber,
        secondary: TtsSelection.system,
        allowOnlineFallback: true,
      ),
    );
    expect(_edgeOfferedAsPrimary(tester), isTrue);
  });

  testWidgets('a saved Edge primary stays selectable so it is not silently changed', (tester) async {
    await _pump(
      tester,
      preferences: const TtsPreferences(primary: TtsSelection.edge, secondary: TtsSelection.system),
    );
    expect(_edgeOfferedAsPrimary(tester), isTrue);
  });
}
