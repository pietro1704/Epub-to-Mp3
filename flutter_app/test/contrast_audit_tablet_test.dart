// CONTRAST-AUDIT, area 5: the tablet shell (navigation rail, wide Settings/Models/Library/Convert).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/root_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';

Future<List<ContrastFinding>> _audit(
  WidgetTester tester,
  AppDestination destination,
  Size size,
  Brightness brightness, {
  required bool highContrast,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  const voiceChannel = MethodChannel('epub_to_mp3/platform_voice');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    voiceChannel,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      voiceChannel,
      null,
    ),
  );
  final key = GlobalKey();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AuditHost(
      boundaryKey: key,
      child: ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.forBrightness(brightness, highContrast: highContrast),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RootScreen(),
        ),
      ),
    ),
  );
  ProviderScope.containerOf(tester.element(find.byType(RootScreen)))
          .read(appDestinationProvider.notifier)
          .state =
      destination;
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(find.byKey(const ValueKey('tablet-navigation')), findsOneWidget);
  return auditContrast(tester, key);
}

void main() {
  const sizes = {
    'landscape 1280x800': Size(1280, 800),
    'portrait 800x1280': Size(800, 1280),
  };
  for (final size in sizes.entries) {
    for (final destination in [
      AppDestination.library,
      AppDestination.settings,
      AppDestination.conversion,
    ]) {
      for (final brightness in Brightness.values) {
        for (final highContrast in [false, true]) {
          final mode =
              '${brightness.name}${highContrast ? ' + Increase Contrast' : ''}';
          testWidgets(
            'tablet ${size.key} ${destination.name}: every text and icon meets WCAG AA in $mode',
            (tester) async {
              final findings = await _audit(
                tester,
                destination,
                size.value,
                brightness,
                highContrast: highContrast,
              );
              final path = Platform.environment['CONTRAST_REPORT'];
              if (path != null) {
                File(path).writeAsStringSync(
                  '## tablet ${size.key} ${destination.name} ($mode): ${findings.length} violation(s)\n'
                  '${findings.map((f) => '- $f').join('\n')}\n\n',
                  mode: FileMode.append,
                );
              }
              expect(findings, isEmpty, reason: findings.join('\n'));
            },
          );
        }
      }
    }
  }
}
