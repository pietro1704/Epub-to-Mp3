import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const converterChannel = MethodChannel(AndroidEmbeddedConverter.channelName);
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  const noticesChannel = MethodChannel('epub_to_mp3/platform_voice');
  late Directory documents;
  late List<MethodCall> converterCalls;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    documents = await Directory.systemTemp.createTemp('manual-range-test-');
    converterCalls = [];
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathsChannel, (_) async => documents.path);
    messenger.setMockMethodCallHandler(noticesChannel, (_) async => null);
    messenger.setMockMethodCallHandler(converterChannel, (call) async {
      converterCalls.add(call);
      if (call.method == 'status') {
        return {'runtimeLoaded': true, 'engineReady': true};
      }
      if (call.method == 'convert') {
        return '{"jobId":"range-result","chapters":[{"sourceIndex":5}]}';
      }
      throw StateError('Unexpected converter call: ${call.method}');
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    for (final channel in [converterChannel, pathsChannel, noticesChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await documents.delete(recursive: true);
  });

  Future<void> submitRange(
    WidgetTester tester,
    String start,
    String end,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          embeddedConverterProvider.overrideWithValue(
            AndroidEmbeddedConverter(channel: converterChannel),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ConvertScreen(initialFilePath: '/owned/book.epub'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'From'), start);
    await tester.enterText(find.widgetWithText(TextField, 'To'), end);
    await tester.scrollUntilVisible(
      find.text('Start conversion'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Start conversion'));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid chapter text never starts the Android converter', (
    tester,
  ) async {
    await submitRange(tester, 'NaN', '6');
    expect(converterCalls, isEmpty);
    expect(find.text('range-result'), findsNothing);
    expect(find.textContaining('non-negative integers'), findsOneWidget);
  });
}
