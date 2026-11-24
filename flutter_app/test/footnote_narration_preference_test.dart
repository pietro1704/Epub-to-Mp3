import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('inline is the default and is not serialized; skip round-trips', () {
    const defaults = TtsPreferences();
    expect(defaults.footnoteNarration, FootnoteNarration.inline);
    expect(defaults.toJson().containsKey('footnote_narration'), isFalse);
    final skip = defaults.withFootnoteNarration(FootnoteNarration.skip);
    expect(skip.toJson()['footnote_narration'], 'skip');
    expect(
      TtsPreferences.fromJson(skip.toJson()).footnoteNarration,
      FootnoteNarration.skip,
    );
    expect(
      TtsPreferences.fromJson(defaults.toJson()).footnoteNarration,
      FootnoteNarration.inline,
    );
    expect(skip.optionsJson(), contains('"footnote_narration":"skip"'));
  });

  test('every copy of the preferences keeps the choice', () {
    const skip = TtsPreferences(footnoteNarration: FootnoteNarration.skip);
    expect(
      skip.withPrimary(TtsSelection.system).footnoteNarration,
      FootnoteNarration.skip,
    );
    expect(
      skip.withAutomaticSystemFallback(false).footnoteNarration,
      FootnoteNarration.skip,
    );
    expect(
      skip.withSupportedPiperQuality().footnoteNarration,
      FootnoteNarration.skip,
    );
  });

  testWidgets(
    'Settings offers the footnote narration option in the Reader card and stores it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      const toggle = ValueKey('tts-footnote-narration');
      await tester.scrollUntilVisible(find.byKey(toggle), 300);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isTrue);
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      expect(
        AppSettings(prefs).ttsPreferences.footnoteNarration,
        FootnoteNarration.skip,
      );
      expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);
      await tester.tap(find.byKey(toggle));
      await tester.pumpAndSettle();
      expect(
        AppSettings(prefs).ttsPreferences.footnoteNarration,
        FootnoteNarration.inline,
      );
    },
  );
}
