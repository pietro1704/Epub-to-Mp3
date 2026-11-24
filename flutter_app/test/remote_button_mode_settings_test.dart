import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'the remote button mode defaults to chapters and is persisted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = MirrorAppSettings(prefs);
      expect(settings.remoteButtonMode, RemoteButtonMode.chapter);
      await settings.setRemoteButtonMode(RemoteButtonMode.seconds);
      expect(
        MirrorAppSettings(prefs).remoteButtonMode,
        RemoteButtonMode.seconds,
      );
      // An unknown stored value falls back to the default (current behaviour).
      SharedPreferences.setMockInitialValues({'remoteButtonMode': 'garbage'});
      expect(
        MirrorAppSettings(await SharedPreferences.getInstance())
            .remoteButtonMode,
        RemoteButtonMode.chapter,
      );
    },
  );

  for (final locale in [
    const Locale('en'),
    const Locale('pt'),
    const Locale('es'),
  ]) {
    testWidgets(
      'Settings offers the remote button mode in ${locale.languageCode} and stores the choice',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        tester.view.physicalSize = const Size(420, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
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
        await tester.pumpAndSettle();
        final choice = find.byKey(const ValueKey('remote-button-mode-choice'));
        await tester.scrollUntilVisible(choice, 300);
        final t = await AppLocalizations.delegate.load(locale);
        expect(find.text(t.remoteButtonModeTitle), findsOneWidget);
        expect(find.text(t.remoteButtonModeChapter), findsOneWidget);
        await tester.tap(find.text(t.remoteButtonModeSeconds));
        await tester.pumpAndSettle();
        expect(
          MirrorAppSettings(prefs).remoteButtonMode,
          RemoteButtonMode.seconds,
        );
        await tester.tap(find.text(t.remoteButtonModeChapter));
        await tester.pumpAndSettle();
        expect(
          MirrorAppSettings(prefs).remoteButtonMode,
          RemoteButtonMode.chapter,
        );
      },
    );
  }
}
