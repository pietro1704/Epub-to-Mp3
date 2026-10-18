import 'dart:convert';
import 'dart:io';

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
  testWidgets(
    'Android explains converter defaults instead of offering ignored options',
    (tester) async {
      const converterChannel = MethodChannel(AndroidEmbeddedConverter.channelName);
      const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
      const noticesChannel = MethodChannel('epub_to_mp3/platform_voice');
      final directory = await Directory.systemTemp.createTemp('manual-options-');
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      messenger.setMockMethodCallHandler(pathsChannel, (_) async => directory.path);
      messenger.setMockMethodCallHandler(noticesChannel, (_) async => null);
      messenger.setMockMethodCallHandler(converterChannel, (call) async {
        calls.add(call);
        if (call.method == 'status') {
          return {'runtimeLoaded': true, 'engineReady': true};
        }
        if (call.method == 'convert') {
          return jsonEncode({
            'jobId': 'manual-options-result',
            'title': 'Options fixture',
            'chapters': [
              {'sourceIndex': 5, 'title': 'One', 'filename': 'one.mp3'},
            ],
          });
        }
        throw StateError('Unexpected native method: ${call.method}');
      });
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              embeddedConverterProvider.overrideWithValue(
                AndroidEmbeddedConverter(channel: converterChannel),
              ),
              apiClientProvider.overrideWith((ref) {
                throw StateError('Android conversion must not request HTTP');
              }),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ConvertScreen(initialFilePath: '/owned/options.epub'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'From'), '5');
        await tester.enterText(find.widgetWithText(TextField, 'To'), '6');
        await tester.scrollUntilVisible(
          find.text('Start conversion'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final offeredCover = find
            .widgetWithText(SwitchListTile, 'Include cover')
            .evaluate()
            .isNotEmpty;
        final offeredNormalization = find
            .widgetWithText(SwitchListTile, 'Normalize audio')
            .evaluate()
            .isNotEmpty;
        final explainedDefaults = find
            .text('Cover and audio processing options are managed by the local converter.')
            .evaluate()
            .isNotEmpty;
        await tester.tap(find.text('Start conversion'));
        await tester.pumpAndSettle();

        expect(calls.map((call) => call.method), ['status', 'convert']);
        final arguments = Map<String, dynamic>.from(calls.last.arguments as Map);
        expect(arguments['inputPath'], '/owned/options.epub');
        expect(arguments['outputPath'], startsWith('${directory.path}/audiobooks/'));
        expect(arguments['chapterStart'], 5);
        expect(arguments['chapterEnd'], 6);
        expect(arguments.containsKey('includeCover'), isFalse);
        expect(arguments.containsKey('normalizeAudio'), isFalse);
        final options = jsonDecode(arguments['optionsJson'] as String) as Map;
        expect(options['language'], 'pt');
        expect(options['models_root'], '${directory.path}/tts-models');
        expect(find.text('manual-options-result'), findsOneWidget);
        expect(offeredCover, isFalse, reason: 'Cover selection is not supported by this adapter');
        expect(offeredNormalization, isFalse, reason: 'Audio normalization is not supported by this adapter');
        expect(explainedDefaults, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final channel in [converterChannel, pathsChannel, noticesChannel]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
        await directory.delete(recursive: true);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
