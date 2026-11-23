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
  tester.view.physicalSize = const Size(1000, 1800);
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

Finder _row(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(ListTile));

Finder _check(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byIcon(Icons.check));

void main() {
  testWidgets('the row shows the engine, with the voice as its subtitle', (tester) async {
    await _pump(tester);
    final primary = find.byKey(const ValueKey('narration-primary-row'));
    expect(find.descendant(of: primary, matching: find.text('Piper')), findsOneWidget);
    expect(find.descendant(of: primary, matching: find.text('Book language')), findsOneWidget);
    final secondary = find.byKey(const ValueKey('narration-secondary-row'));
    expect(find.descendant(of: secondary, matching: find.text('System voice')), findsOneWidget);
    expect(find.descendant(of: secondary, matching: find.text('Installed system voice')), findsOneWidget);
  });

  testWidgets('the first level is the engine; Edge needs the online consent', (tester) async {
    await _pump(tester);
    await tester.tap(_row('narration-primary-row'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('narration-engine-system')), findsOneWidget);
    expect(find.byKey(const ValueKey('narration-engine-piper')), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('narration-engine-edge'))).enabled, isFalse);
    expect(find.textContaining('Allow online fallback'), findsWidgets);
    expect(_check('narration-engine-piper'), findsOneWidget, reason: 'the active engine is marked');
  });

  testWidgets('choosing an engine with one voice commits it and the check follows the tap', (tester) async {
    final prefs = await _pump(tester);
    await tester.tap(_row('narration-primary-row'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('narration-engine-system')));
    await tester.pump();
    expect(_check('narration-engine-system'), findsOneWidget, reason: 'marked before the sheet finishes closing');
    expect(_check('narration-engine-piper'), findsNothing);
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.primary.engine, 'system');
    final primary = find.byKey(const ValueKey('narration-primary-row'));
    expect(find.descendant(of: primary, matching: find.text('System voice')), findsOneWidget);
  });

  testWidgets('Piper opens its voices; the picked voice is marked at the tap and saved', (tester) async {
    final prefs = await _pump(tester);
    await tester.tap(_row('narration-primary-row'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('narration-engine-piper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('narration-picker-back')), findsOneWidget);
    final faber = find.text('Faber medium');
    expect(faber, findsOneWidget);
    await tester.tap(faber);
    await tester.pump();
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the new voice is marked at once');
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.primary.modelId, 'pt_BR-faber-medium');
  });

  testWidgets('the secondary voice can be set to None', (tester) async {
    final prefs = await _pump(tester);
    await tester.tap(_row('narration-secondary-row'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('narration-engine-none')));
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.secondary, isNull);
    final secondary = find.byKey(const ValueKey('narration-secondary-row'));
    expect(find.descendant(of: secondary, matching: find.text('None')), findsOneWidget);
  });
}
