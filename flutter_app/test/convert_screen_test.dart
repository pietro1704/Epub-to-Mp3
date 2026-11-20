import 'dart:async';
import 'dart:io';
import 'package:flutter_app/services/conversion/local_conversion_job.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
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

final class _CatalogConverter extends UnavailableEmbeddedConverter {
  final catalog = Completer<String>();

  @override
  Future<String> ttsModels() => catalog.future;
}

Future<void> _pumpManualResult(
  WidgetTester tester,
  SharedPreferences prefs,
  Future<String> Function(ConversionRequest) starter, {
  EmbeddedConverter? converter,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        if (converter != null)
          embeddedConverterProvider.overrideWithValue(converter),
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
  testWidgets('manual conversion captures automatic Piper without waiting for the catalog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = _CatalogConverter();
    ConversionRequest? request;
    await _pumpManualResult(tester, prefs, (value) async {
      request = value;
      return 'job';
    }, converter: converter);
    await tester.pumpAndSettle();
    expect(converter.catalog.isCompleted, isFalse);
    expect(request?.ttsPreferences.primary.modelId, 'piper-auto');
    expect(request?.ttsPreferences.primary.session, isNull);
    expect(request?.language, isNull);
    expect(request?.ttsPreferences.secondary?.engine, 'system');
    expect(request?.ttsPreferences.allowOnlineFallback, isFalse);
  });

  registerManualConversionHistoryCases();
  registerManualConversionControlsCases();
  registerManualConversionCompletionCases();
}
