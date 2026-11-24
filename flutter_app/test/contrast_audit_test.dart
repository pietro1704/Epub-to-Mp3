import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';

Future<List<ContrastFinding>> _audit(
  WidgetTester tester,
  Widget screen,
  Brightness brightness, {
  bool highContrast = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  // The Convert screen listens to the platform-voice stream: answer its channel calls.
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
  tester.view.physicalSize = const Size(400, 900);
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
          home: screen,
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return auditContrast(tester, key);
}

void _report(
  String area,
  Brightness brightness,
  List<ContrastFinding> findings,
) {
  final path = Platform.environment['CONTRAST_REPORT'];
  if (path == null) return;
  File(path).writeAsStringSync(
    '## $area (${brightness.name}): ${findings.length} violation(s)\n'
    '${findings.map((f) => '- $f').join('\n')}\n\n',
    mode: FileMode.append,
  );
}

void main() {
  final screens = <String, Widget>{
    'Settings': const SettingsScreen(),
    'Models': const ModelsScreen(),
    'Library': const LibraryScreen(),
    'Convert': const ConvertScreen(),
  };
  for (final entry in screens.entries) {
    for (final brightness in Brightness.values) {
      for (final highContrast in [false, true]) {
        final mode =
            '${brightness.name}${highContrast ? ' + Increase Contrast' : ''}';
        testWidgets(
          '${entry.key}: every text and icon meets WCAG AA in $mode',
          (tester) async {
            final findings = await _audit(
              tester,
              entry.value,
              brightness,
              highContrast: highContrast,
            );
            _report(
              '${entry.key}${highContrast ? ' (high contrast)' : ''}',
              brightness,
              findings,
            );
            expect(findings, isEmpty, reason: findings.join('\n'));
          },
        );
      }
    }
  }
}
