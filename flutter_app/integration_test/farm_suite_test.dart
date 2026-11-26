// The device farm's regression suite (card ANDROID-DEVICE-TEST-FARM). ONE APK is built on the
// Arch host from this target; the A8 and the tablet run different halves of it in parallel. The
// shard comes from `files/farm_shard` in the app's data directory (written with `run-as` by
// scripts/device_farm/device_farm.rb): "a" or "b"; without it the whole suite runs.
//
// The journeys are language independent (icons and keys, not labels), never reset or clear
// anything, and restore every preference they touch, so the models, books and preferences on a
// device survive any number of rounds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Future<String> _shard() async {
  final directory = await getApplicationSupportDirectory();
  final file = File('${directory.path}/farm_shard');
  return file.existsSync() ? file.readAsStringSync().trim() : 'all';
}

Future<void> _settle(WidgetTester tester, [int steps = 12]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Opens a root destination by its icon (the labels depend on the app language).
Future<void> _openTab(WidgetTester tester, IconData icon) async {
  final target = find.byIcon(icon).hitTestable();
  expect(target, findsWidgets, reason: 'the navigation offers $icon');
  await tester.tap(target.last);
  await _settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('farm journeys', (tester) async {
    final shard = await _shard();
    debugPrint('FARM_SHARD=$shard');
    bool mine(String journey) => shard == 'all' || shard == journey;
    app.main();
    await _settle(tester, 30);
    // The app reopens the book that was last read, and the reader hides the navigation: leave it
    // so the journeys start from the root shell on a device that was used by hand.
    if (find.byIcon(Icons.library_books_outlined).evaluate().isEmpty) {
      await tester.binding.handlePopRoute();
      await _settle(tester, 4);
    }

    // Both devices: the app starts and offers its three root destinations.
    expect(find.byIcon(Icons.library_books_outlined), findsWidgets);
    expect(find.byIcon(Icons.settings_outlined), findsWidgets);
    expect(find.byIcon(Icons.auto_fix_high), findsWidgets);

    if (mine('a')) {
      // Settings: the footnote narration switch toggles and is restored.
      await _openTab(tester, Icons.settings_outlined);
      final toggle = find.byKey(const ValueKey('tts-footnote-narration'));
      await tester.scrollUntilVisible(
        toggle,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      final before = tester.widget<SwitchListTile>(toggle).value;
      await tester.tap(toggle);
      await _settle(tester, 4);
      expect(tester.widget<SwitchListTile>(toggle).value, !before);
      await tester.tap(toggle);
      await _settle(tester, 4);
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        before,
        reason: 'the preference is restored',
      );

      // Converter destination opens.
      await _openTab(tester, Icons.auto_fix_high);
      expect(find.byType(Scaffold), findsWidgets);
    }

    if (mine('b')) {
      // Settings → Models → Languages: the route opens with ordered groups and language rows.
      await _openTab(tester, Icons.settings_outlined);
      final modelsRow = find.byKey(const ValueKey('settings-models-row'));
      await tester.scrollUntilVisible(
        modelsRow,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(modelsRow);
      await _settle(tester, 15);
      await tester.tap(find.byKey(const ValueKey('models-languages-row')));
      await _settle(tester, 20);
      expect(
        find
                .byKey(const ValueKey('models-group-others'))
                .evaluate()
                .isNotEmpty ||
            find
                .byKey(const ValueKey('models-group-popular'))
                .evaluate()
                .isNotEmpty ||
            find
                .byKey(const ValueKey('models-group-system'))
                .evaluate()
                .isNotEmpty,
        isTrue,
        reason: 'at least one language group is listed',
      );
      await tester.tap(find.byType(BackButton).last);
      await _settle(tester, 6);
      await tester.tap(find.byType(BackButton).last);
      await _settle(tester, 6);

      // Library destination opens.
      await _openTab(tester, Icons.library_books_outlined);
      expect(find.byType(Scaffold), findsWidgets);
    }
  });
}
