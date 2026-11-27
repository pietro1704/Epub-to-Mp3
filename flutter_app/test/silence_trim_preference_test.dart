import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(SharedPreferences prefs, Widget home) => ProviderScope(
  overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  test(
    'light is the default and is not serialized; every level round-trips',
    () {
      const defaults = TtsPreferences();
      expect(defaults.silenceTrim, SilenceTrim.light);
      expect(defaults.toJson().containsKey('silence_trim'), isFalse);
      for (final level in [
        SilenceTrim.off,
        SilenceTrim.medium,
        SilenceTrim.strong,
      ]) {
        final saved = defaults.withSilenceTrim(level);
        expect(saved.toJson()['silence_trim'], level.name);
        expect(saved.optionsJson(), contains('"silence_trim":"${level.name}"'));
        expect(TtsPreferences.fromJson(saved.toJson()).silenceTrim, level);
      }
      expect(
        TtsPreferences.fromJson(defaults.toJson()).silenceTrim,
        SilenceTrim.light,
      );
      expect(
        TtsPreferences.fromJson({...defaults.toJson(), 'silence_trim': 'bogus'})
            .silenceTrim,
        SilenceTrim.light,
      );
    },
  );

  test('every copy of the preferences keeps the level', () {
    const strong = TtsPreferences(silenceTrim: SilenceTrim.strong);
    expect(
      strong.withPrimary(TtsSelection.system).silenceTrim,
      SilenceTrim.strong,
    );
    expect(
      strong.withAutomaticSystemFallback(false).silenceTrim,
      SilenceTrim.strong,
    );
    expect(strong.withSupportedPiperQuality().silenceTrim, SilenceTrim.strong);
    expect(
      strong.withFootnoteNarration(FootnoteNarration.skip).silenceTrim,
      SilenceTrim.strong,
    );
    expect(
      const TtsPreferences(footnoteNarration: FootnoteNarration.skip)
          .withSilenceTrim(SilenceTrim.off)
          .footnoteNarration,
      FootnoteNarration.skip,
    );
  });

  testWidgets('Settings stores the default silence trim level', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(prefs, const SettingsScreen()));
    await tester.pumpAndSettle();
    const field = ValueKey('tts-silence-trim');
    await tester.scrollUntilVisible(find.byKey(field), 300);
    await tester.pumpAndSettle();
    expect(find.text('Light'), findsWidgets);
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Strong').last);
    await tester.pumpAndSettle();
    expect(AppSettings(prefs).ttsPreferences.silenceTrim, SilenceTrim.strong);
  });

  testWidgets(
    'a manual conversion starts with the saved level and can override it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await AppSettings(prefs).setTtsPreferences(
        const TtsPreferences.appDefaults().withSilenceTrim(SilenceTrim.medium),
      );
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <ConversionRequest>[];
      await tester.pumpWidget(
        _app(
          prefs,
          ConvertScreen(
            initialFilePath: '/tmp/manual.epub',
            startConversion: (request) async {
              requests.add(request);
              return 'job-1';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      const field = ValueKey('convert-silence-trim');
      await tester.scrollUntilVisible(
        find.byKey(field),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Medium'), findsWidgets);
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Start conversion'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Start conversion'));
      await tester.pump();
      expect(requests.single.ttsPreferences.silenceTrim, SilenceTrim.off);
      // The default in Settings is untouched by a per-conversion choice.
      expect(AppSettings(prefs).ttsPreferences.silenceTrim, SilenceTrim.medium);
    },
  );
}
