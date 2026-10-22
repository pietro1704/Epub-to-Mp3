import 'dart:async';
import 'dart:io';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'manual_conversion_history_cases.dart';
part 'manual_conversion_controls_cases.dart';
part 'manual_conversion_completion_cases.dart';

class _RefusingHistoryPreferences extends Fake implements SharedPreferences {
  int writes = 0;
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    return false;
  }
}

Future<void> _pumpManualResult(
  WidgetTester tester,
  SharedPreferences prefs,
  Future<String> Function(ConversionRequest) starter,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWith((ref) {
          throw StateError('Completed local conversion must not request HTTP');
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConvertScreen(
          initialFilePath: '/tmp/manual.epub',
          startConversion: starter,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('Start conversion'), 200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Start conversion'));
  await tester.pump();
}

void main() {
  registerManualConversionHistoryCases();
  registerManualConversionControlsCases();
  registerManualConversionCompletionCases();
}
