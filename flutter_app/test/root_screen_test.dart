import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/l10n/app_localizations_en.dart';
import 'package:flutter_app/l10n/app_localizations_es.dart';
import 'package:flutter_app/l10n/app_localizations_pt.dart';
import 'package:flutter_app/screens/root_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RootScreen(),
    ),
  );
}

void main() {
  testWidgets('tablet uses a sidebar rather than phone navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await _mockPrefs();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tablet-navigation')), findsOneWidget);
    expect(find.byType(CupertinoTabBar), findsNothing);
  });
  group('RootScreen', () {
    test(
      'provides a localized label for the Convert destination in every locale',
      () {
        expect(AppLocalizationsEn().convertTitle, 'Convert');
        expect(AppLocalizationsPt().convertTitle, 'Converter');
        expect(AppLocalizationsEs().convertTitle, 'Convertir');
      },
    );

    testWidgets('has the three native compact destinations', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      expect(find.byType(CupertinoTabBar), findsOneWidget);
      // "Reader" appears both in the nav bar label and the AppBar title,
      // so we check at least one. Same for "Library" vs library tab content.
      expect(find.text('Library'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Convert'), findsWidgets);
    });

    testWidgets('library is shown before a book is opened', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      // Reader tab empty state text
      expect(find.text('Your library is empty'), findsOneWidget);
    });

    testWidgets('convert destination is localized in every supported locale', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const expectedTitles = {
        'en': 'Convert',
        'es': 'Convertir',
        'pt': 'Converter',
      };

      for (final entry in expectedTitles.entries) {
        final prefs = await _mockPrefs();
        await t.pumpWidget(
          ProviderScope(
            overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              locale: Locale(entry.key),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const RootScreen(),
            ),
          ),
        );
        await t.pumpAndSettle();

        expect(find.text(entry.value), findsWidgets);
      }
    });

    testWidgets('tapping Library navigates to library tab', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      await t.tap(find.text('Library').last);
      await t.pumpAndSettle();

      // Library screen empty state
      expect(find.text('Your library is empty'), findsOneWidget);
    });

    testWidgets(
      'entering Jobs refreshes conversions created while the tab was mounted',
      (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final prefs = await _mockPrefs();
        await t.pumpWidget(_wrap(prefs));
        await t.pumpAndSettle();
        await ConversionJobCoordinator(LocalConversionJobStore(prefs))
            .createJob(
              bookId: 'new-local-book',
              jobId: 'new-local-job',
              chapters: const [LocalConversionChapterSpec(0, 'One')],
            );
        await t.tap(find.text('Convert').last);
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Jobs'));
        await t.pumpAndSettle();
        expect(find.text('new-local-book'), findsOneWidget);
        expect(find.text('No conversions yet'), findsNothing);
      },
    );

    testWidgets('tapping Settings navigates to settings tab', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(prefs));
      await t.pumpAndSettle();

      await t.tap(find.text('Settings').last);
      await t.pumpAndSettle();

      expect(find.text('Primary narration'), findsOneWidget);
    });
  });
}
