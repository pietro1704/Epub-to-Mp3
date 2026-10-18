import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/desktop_embedded_converter.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A synthetic converter-ffi ABI, not Rust synthesis or a system TTS backend.
const _desktopFixture = r'''
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
typedef struct { char output[4096]; } Control;
void* converter_session_open(const char* input) { return strdup(input); }
char* converter_session_metadata_json(void* session) { return strdup("{}"); }
void converter_session_free(void* session) { free(session); }
void converter_string_free(char* value) { free(value); }
char* converter_last_error(void) { return strdup("Invalid options fixture request"); }
_Bool converter_session_set_desktop_platform_tts_v1(void* session) { return 1; }
void* converter_job_control_create(void) { return calloc(1, sizeof(Control)); }
void converter_job_control_cancel(Control* control) {}
void converter_job_control_free(Control* control) {
 if (control->output[0]) {
  char path[8192]; snprintf(path, sizeof(path), "%s/control-freed", control->output);
  FILE* file = fopen(path, "wb"); if (file) fclose(file);
 }
 free(control);
}
char* converter_session_convert_controlled_job_options_json_v1(void* session,
 const char* output, const char* job, const char* options, int start, int end,
 void* progress, void* chapter, void* context, Control* control) {
 if (strcmp(session, "/owned/options.epub") || start != 5 || end != 6 ||
     !strstr(options, "pt_BR-faber-medium") || !strstr(options, "tts-models")) return NULL;
 const char* name = strrchr(output, '/');
 if (!name || strcmp(name + 1, job)) return NULL;
 if (mkdir(output, 0700)) return NULL;
 snprintf(control->output, sizeof(control->output), "%s", output);
 char path[8192]; snprintf(path, sizeof(path), "%s/request.json", output);
 FILE* file = fopen(path, "wb"); if (!file) return NULL;
 fprintf(file, "{\"input\":\"%s\",\"output\":\"%s\",\"job\":\"%s\",\"start\":%d,\"end\":%d,\"options\":%s}", (char*)session, output, job, start, end, options);
 fclose(file);
 char result[8192];
 snprintf(result, sizeof(result), "{\"manifest\":{\"jobId\":\"%s\",\"title\":\"Options fixture\",\"chapters\":[{\"sourceIndex\":5,\"title\":\"One\",\"filename\":\"one.mp3\"}]}}", job);
 return strdup(result);
}
''';

void main() {
  late Directory directory;
  late SharedPreferences prefs;
  late Directory desktopDirectory;
  late String desktopLibrary;
  final supportsFixture = Platform.isLinux || Platform.isMacOS;

  setUpAll(() async {
    if (!supportsFixture) return;
    desktopDirectory = await Directory.systemTemp.createTemp(
      'options-desktop-abi-',
    );
    final source = File('${desktopDirectory.path}/fixture.c');
    await source.writeAsString(_desktopFixture);
    desktopLibrary =
        '${desktopDirectory.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final result = await Process.run('cc', [
      '-std=c11',
      '-D_DEFAULT_SOURCE',
      '-shared',
      '-fPIC',
      source.path,
      '-o',
      desktopLibrary,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  tearDownAll(() async {
    if (supportsFixture) await desktopDirectory.delete(recursive: true);
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('manual-options-');
    await Directory('${directory.path}/audiobooks').create();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      AndroidEmbeddedConverter.channelName,
      'plugins.flutter.io/path_provider',
      'epub_to_mp3/platform_voice',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    await directory.delete(recursive: true);
  });

  Future<void> pumpOptionsScreen(
    WidgetTester tester, {
    required EmbeddedConverter converter,
    ConversionStarter? starter,
  }) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('epub_to_mp3/platform_voice'),
      (_) async => null,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          embeddedConverterProvider.overrideWithValue(converter),
          apiClientProvider.overrideWith((ref) {
            throw StateError('Manual conversion must not request HTTP');
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(
            initialFilePath: '/owned/options.epub',
            startConversion: starter,
          ),
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
  }

  testWidgets(
    'Android explains converter defaults instead of offering ignored options',
    (tester) async {
      const converterChannel = MethodChannel(
        AndroidEmbeddedConverter.channelName,
      );
      const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
      const noticesChannel = MethodChannel('epub_to_mp3/platform_voice');
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathsChannel,
        (_) async => directory.path,
      );
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
            .text(
              'Cover and audio processing options are managed by the local converter.',
            )
            .evaluate()
            .isNotEmpty;
        expect(
          offeredCover,
          isFalse,
          reason: 'Cover selection is not supported by this adapter',
        );
        expect(
          offeredNormalization,
          isFalse,
          reason: 'Audio normalization is not supported by this adapter',
        );
        expect(explainedDefaults, isTrue);
        await tester.tap(find.text('Start conversion'));
        await tester.pumpAndSettle();

        expect(calls.map((call) => call.method), ['status', 'convert']);
        final arguments = Map<String, dynamic>.from(
          calls.last.arguments as Map,
        );
        expect(arguments['inputPath'], '/owned/options.epub');
        expect(
          arguments['outputPath'],
          startsWith('${directory.path}/audiobooks/'),
        );
        expect(arguments['chapterStart'], 5);
        expect(arguments['chapterEnd'], 6);
        expect(arguments.containsKey('includeCover'), isFalse);
        expect(arguments.containsKey('normalizeAudio'), isFalse);
        final options = jsonDecode(arguments['optionsJson'] as String) as Map;
        expect(options['language'], 'pt');
        expect(options['models_root'], '${directory.path}/tts-models');
        expect(find.text('manual-options-result'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final channel in [
          converterChannel,
          pathsChannel,
          noticesChannel,
        ]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final unavailableAtStatus in [true, false]) {
    testWidgets(
      'Android ${unavailableAtStatus ? 'unavailable runtime' : 'conversion failure'} stays visible without HTTP',
      (tester) async {
        const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            if (call.method == 'status') {
              return {
                'runtimeLoaded': true,
                'engineReady': !unavailableAtStatus,
              };
            }
            if (call.method == 'convert') {
              throw PlatformException(
                code: 'OPTIONS_FIXTURE_FAILED',
                message: 'Owned conversion failed',
              );
            }
            throw StateError('Unexpected native method: ${call.method}');
          },
        );
        try {
          await pumpOptionsScreen(
            tester,
            converter: AndroidEmbeddedConverter(channel: channel),
          );
          expect(
            find.widgetWithText(SwitchListTile, 'Include cover'),
            findsNothing,
          );
          expect(
            find.widgetWithText(SwitchListTile, 'Normalize audio'),
            findsNothing,
          );
          await tester.tap(find.text('Start conversion'));
          await tester.pumpAndSettle();
          expect(
            calls.map((call) => call.method),
            unavailableAtStatus ? ['status'] : ['status', 'convert'],
          );
          expect(
            find.textContaining(
              unavailableAtStatus
                  ? 'runtime is not ready'
                  : 'Owned conversion failed',
            ),
            findsOneWidget,
          );
          expect(find.byKey(const Key('conversion-job-id')), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(find.text('Start conversion'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'desktop options UI uses the real adapter and isolate with a synthetic ABI',
    (tester) async {
      final converter = DesktopEmbeddedConverter(libraryPath: desktopLibrary);
      try {
        await pumpOptionsScreen(tester, converter: converter);
        expect(
          find.widgetWithText(SwitchListTile, 'Include cover'),
          findsNothing,
        );
        expect(
          find.widgetWithText(SwitchListTile, 'Normalize audio'),
          findsNothing,
        );
        expect(
          find.text(
            'Cover and audio processing options are managed by the local converter.',
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Start conversion'));
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (find
              .byKey(const Key('conversion-job-id'))
              .evaluate()
              .isEmpty) {
            if (DateTime.now().isAfter(deadline)) {
              fail(
                'Desktop fixture did not complete: ${tester.takeException()}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        final job = tester
            .widget<Text>(find.byKey(const Key('conversion-job-id')))
            .data!;
        final output = '${directory.path}/audiobooks/$job';
        final request = await tester.runAsync(() async {
          expect(await File('$output/control-freed').exists(), isTrue);
          return jsonDecode(await File('$output/request.json').readAsString())
              as Map;
        });
        expect(request!['input'], '/owned/options.epub');
        expect(request['output'], output);
        expect(request['job'], job);
        expect(request['start'], 5);
        expect(request['end'], 6);
        expect(request['options']['language'], 'pt');
        expect(
          request['options']['models_root'],
          '${directory.path}/tts-models',
        );
        expect(
          request['options']['tts_preferences']['primary']['engine'],
          'piper',
        );
        expect(
          request['options']['tts_preferences']['primary']['model_id'],
          'pt_BR-faber-medium',
        );
        expect(request['options'].containsKey('include_cover'), isFalse);
        expect(request['options'].containsKey('normalize_audio'), isFalse);
        expect(find.byType(LinearProgressIndicator), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
    skip: !supportsFixture,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'non-embedded route preserves option switches and selected request values',
    (tester) async {
      final requests = <ConversionRequest>[];
      try {
        await pumpOptionsScreen(
          tester,
          converter: UnavailableEmbeddedConverter(),
          starter: (request) async {
            requests.add(request);
            return 'legacy-options-result';
          },
        );
        final cover = find.widgetWithText(SwitchListTile, 'Include cover');
        final normalize = find.widgetWithText(
          SwitchListTile,
          'Normalize audio',
        );
        expect(tester.widget<SwitchListTile>(cover).value, isTrue);
        expect(tester.widget<SwitchListTile>(normalize).value, isTrue);
        expect(
          find.text(
            'Cover and audio processing options are managed by the local converter.',
          ),
          findsNothing,
        );
        await tester.ensureVisible(cover);
        await tester.tap(cover);
        await tester.pump();
        await tester.ensureVisible(normalize);
        await tester.tap(normalize);
        await tester.pump();
        await tester.ensureVisible(find.text('Start conversion'));
        await tester.tap(find.text('Start conversion'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(requests.single.filePath, '/owned/options.epub');
        expect(requests.single.chapterStart, 5);
        expect(requests.single.chapterEnd, 6);
        expect(requests.single.includeCover, isFalse);
        expect(requests.single.normalizeAudio, isFalse);
        expect(find.text('legacy-options-result'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
