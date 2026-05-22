import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_settings_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SharedPreferences> mockPrefs([Map<String, Object>? seed]) async {
    SharedPreferences.setMockInitialValues(seed ?? {});
    return SharedPreferences.getInstance();
  }

  Widget wrap(SharedPreferences prefs) {
    return ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ReaderSettingsSheet()),
      ),
    );
  }

  group('ReaderSettingsSheet', () {
    testWidgets('renders theme section with 6 theme circles', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Theme'), findsOneWidget);
      // 6 non-custom themes
      for (final theme in ReaderTheme.values) {
        if (theme == ReaderTheme.custom) continue;
        expect(find.text(theme.displayName), findsOneWidget);
      }
    });

    testWidgets('renders font family segmented button', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Serif'), findsOneWidget);
      expect(find.text('Sans'), findsOneWidget);
      expect(find.text('Mono'), findsOneWidget);
    });

    testWidgets('renders font size controls', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Size'), findsOneWidget);
      // Default step 3 = 24pt
      expect(find.text('24pt'), findsOneWidget);
    });

    testWidgets('renders layout section', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Layout'), findsOneWidget);
      expect(find.text('Scrolling'), findsOneWidget);
      expect(find.text('Paginated'), findsOneWidget);
    });

    testWidgets('renders line spacing and margin sliders', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Line spacing'), findsOneWidget);
      expect(find.text('Margin'), findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets('tapping font size + increments step', (t) async {
      final prefs = await mockPrefs({'readerFontSize': 2});
      await t.pumpWidget(wrap(prefs));
      expect(find.text('20pt'), findsOneWidget);
      await t.tap(find.byIcon(Icons.text_increase));
      await t.pumpAndSettle();
      expect(find.text('24pt'), findsOneWidget);
    });

    testWidgets('tapping font size - decrements step', (t) async {
      final prefs = await mockPrefs({'readerFontSize': 3});
      await t.pumpWidget(wrap(prefs));
      expect(find.text('24pt'), findsOneWidget);
      await t.tap(find.byIcon(Icons.text_decrease));
      await t.pumpAndSettle();
      expect(find.text('20pt'), findsOneWidget);
    });

    testWidgets('renders Show page numbers switch (on by default)',
        (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Show page numbers'), findsOneWidget);
      final sw = t.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue);
    });

    testWidgets('toggling Show page numbers persists', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      await t.ensureVisible(find.byType(SwitchListTile));
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      expect(prefs.getBool('readerShowPageNumbers'), isFalse);
    });

    testWidgets('renders Alignment segmented button (justified default)',
        (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      expect(find.text('Alignment'), findsOneWidget);
      expect(find.text('Justified'), findsOneWidget);
      expect(find.text('Left'), findsOneWidget);
    });

    testWidgets('tapping Left alignment persists', (t) async {
      final prefs = await mockPrefs();
      await t.pumpWidget(wrap(prefs));
      await t.ensureVisible(find.text('Left'));
      await t.tap(find.text('Left'));
      await t.pumpAndSettle();
      expect(prefs.getString('readerTextAlignment'), 'left');
    });
  });
}
