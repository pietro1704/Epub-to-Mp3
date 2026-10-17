import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final unsafeJob in [false, true]) {
    testWidgets(
      unsafeJob
          ? 'unsafe Android job identity warns without retrying a completed conversion'
          : 'Android manual history resolves the actual nested JNI outputs',
      (tester) async {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        const native = MethodChannel(AndroidEmbeddedConverter.channelName);
        const voice = MethodChannel('epub_to_mp3/platform_voice');
        final messenger = tester.binding.defaultBinaryMessenger;
        late Directory directory;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'android-manual-history-',
          );
        });
        final jobId = unsafeJob ? '../outside' : 'embedded-4321';
        const filenames = ['chapter%20#part.mp3', 'chapter_0007.mp3'];
        late String requestRoot;
        late Map<String, dynamic> capturedOptions;
        var conversions = 0;
        messenger.setMockMethodCallHandler(paths, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return '${directory.path}/documents';
          }
          if (call.method == 'getApplicationSupportDirectory') {
            return '${directory.path}/support';
          }
          throw StateError('Unexpected path lookup: ${call.method}');
        });
        messenger.setMockMethodCallHandler(voice, (_) async => null);
        messenger.setMockMethodCallHandler(native, (call) async {
          if (call.method == 'status') return {'engineReady': true};
          expect(call.method, 'convert');
          conversions++;
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          requestRoot = arguments['outputPath'] as String;
          capturedOptions =
              jsonDecode(arguments['optionsJson'] as String)
                  as Map<String, dynamic>;
          final jobDirectory = Directory('$requestRoot/$jobId');
          if (!unsafeJob) {
            jobDirectory.createSync(recursive: true);
            for (final filename in filenames) {
              // This fake native boundary establishes files, not playable audio.
              File(
                '${jobDirectory.path}/$filename',
              ).writeAsStringSync('owned audio fixture');
            }
          }
          return jsonEncode({
            'audioPath': '${jobDirectory.path}/${filenames.first}',
            'manifest': {
              'jobId': jobId,
              'title': 'Owned Android book',
              'usedSelections': [TtsSelection.faber.toJson()],
              'chapters': [
                for (var index = 0; index < filenames.length; index++)
                  {
                    'sourceIndex': index + 5,
                    'title': 'Chapter ${index + 6}',
                    'filename': filenames[index],
                  },
              ],
            },
          });
        });
        try {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final input = '${directory.path}/owned.epub';
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                sharedPrefsProvider.overrideWithValue(prefs),
                embeddedConverterProvider.overrideWithValue(
                  AndroidEmbeddedConverter(),
                ),
                apiClientProvider.overrideWith(
                  (ref) => throw StateError('No HTTP conversion'),
                ),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: ConvertScreen(initialFilePath: input),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Start conversion'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Start conversion'));
          await tester.pumpAndSettle();
          final history = await LocalConversionJobStore(prefs).loadHistory();
          if (unsafeJob) {
            expect(history.jobs, isEmpty);
            expect(
              find.textContaining(
                'Conversion completed, but its history could not be saved:',
              ),
              findsOneWidget,
            );
            expect(find.byKey(const Key('conversion-job-id')), findsOneWidget);
            expect(find.text('Retry'), findsNothing);
            expect(conversions, 1);
            expect(tester.takeException(), isNull);
            return;
          }
          final restored = history.jobs.single;
          expect(conversions, 1);
          expect(restored.bookId, input);
          expect(restored.jobId, jobId);
          expect(restored.chapters.map((chapter) => chapter.index), [5, 6]);
          expect(restored.status, LocalConversionJobStatus.completed);
          expect(
            restored.usedSelections.single.toJson(),
            TtsSelection.faber.toJson(),
          );
          final preferences = capturedOptions['tts_preferences'] as Map;
          expect(preferences['primary'], TtsSelection.faber.toJson());
          expect(
            jsonDecode(restored.conversionOptionsJson!)['tts_preferences'],
            preferences,
          );
          final expected = [
            for (final filename in filenames) '$requestRoot/$jobId/$filename',
          ];
          expect(restored.completedOutputs, expected);
          expect(
            restored.chapters.map((chapter) => chapter.outputPath),
            expected,
          );
          for (final path in restored.completedOutputs) {
            expect(
              File(path).existsSync(),
              true,
              reason: 'History must reference the actual JNI output',
            );
          }
          expect(find.byKey(const Key('conversion-job-id')), findsOneWidget);
          expect(find.text('Retry'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          messenger.setMockMethodCallHandler(native, null);
          messenger.setMockMethodCallHandler(voice, null);
          messenger.setMockMethodCallHandler(paths, null);
          debugDefaultTargetPlatformOverride = previousPlatform;
          await tester.runAsync(() => directory.delete(recursive: true));
        }
      },
    );
  }
}
