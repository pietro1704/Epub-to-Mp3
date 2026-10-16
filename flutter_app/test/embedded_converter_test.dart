import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';

class FakeConverter implements EmbeddedConverter {
  int calls = 0;

  @override
  Future<Uint8List> edgeProbe(String text, {String? locale}) async =>
      Uint8List.fromList(const [1]);

  @override
  Future<void> speakFallback(String text, {required String locale}) async {}

  @override
  Future<String> synthesizeFallback(
    String text, {
    required String locale,
    required String path,
  }) async => path;

  @override
  Future<EbookFulltext> parse({
    required String inputPath,
    String jobId = '',
  }) async => EbookFulltext.fromJson({'jobId': jobId, 'chapters': []});

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    int? chapterStart,
    int? chapterEnd,
    String? optionsJson,
  }) async {
    calls++;
    return outputPath;
  }

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async => ConvertedChapterAudio(
    chapterIndex: chapterIndex,
    path: outputPath,
    title: 'Chapter $chapterIndex',
  );

  @override
  Future<String> ttsModels() async => '[]';

  @override
  Future<String> ttsDefaultEngine({
    required String language,
    required String platform,
    int? androidApi,
  }) async => 'piper';

  @override
  Future<String> ttsInstalledReadyEngine({
    required String language,
    required String platform,
    required String installedModelIdsJson,
    required String readyModelIdsJson,
    int? androidApi,
  }) async => 'none';

  @override
  Future<String> installTtsModel({
    required String modelId,
    required String url,
    required String sha256,
    required String root,
  }) async => '$root/$modelId/model.bin';

  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) async => '$root/$modelId';

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => null;

  @override
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) async => true;
}

void main() {
  test(
    'native chapter decoding retains actual voice and opaque Rust policy state',
    () {
      final chapter = ConvertedChapterAudio.fromNativeResult(
        jsonEncode({
          'audioPath': '/chapter.mp3',
          'manifest': {
            'chapters': [
              {'sourceIndex': 5, 'title': 'Chapter 5'},
            ],
            'usedSelections': [
              {
                'engine': 'edge',
                'model_id': null,
                'voice': 'pt-BR-FranciscaNeural',
              },
            ],
            'ttsPolicyState': {'consecutive_failures': 2},
            'fallbackUsed': true,
          },
        }),
        expectedChapterIndex: 5,
      );
      expect(chapter.usedSelections.single.voice, 'pt-BR-FranciscaNeural');
      expect(chapter.fallbackUsed, true);
      expect(chapter.ttsPolicyState, {'consecutive_failures': 2});
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'owned output cancellation leaves other conversions of the same input alone',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return null;
          });
      await AndroidEmbeddedConverter(
        channel: channel,
      ).cancelConversion(outputPath: '/tmp/manual-request');
      expect(received?.method, 'cancelConversion');
      expect(received?.arguments, {'outputPath': '/tmp/manual-request'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test(
    'Android cancellation forwards the active input identity to Rust',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return null;
          });
      await AndroidEmbeddedConverter(
        channel: channel,
      ).cancelConversion(inputPath: '/tmp/book.epub');
      expect(received?.method, 'cancelConversion');
      expect(received?.arguments, {'inputPath': '/tmp/book.epub'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test('Android fallback uses the TTS file synthesis channel', () async {
    const channel = MethodChannel('epub_to_mp3/android_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'synthesizeToFile');
          expect(call.arguments, {
            'text': 'texto de teste',
            'locale': 'pt-BR',
            'path': '/tmp/chapter.mp3',
          });
          return '/tmp/chapter.mp3';
        });

    final result = await AndroidEmbeddedConverter().synthesizeFallback(
      'texto de teste',
      locale: 'pt-BR',
      path: '/tmp/chapter.mp3',
    );
    expect(result, '/tmp/chapter.mp3');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Android chapter conversion asks Rust for exactly one chapter',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'status') {
              return {'engineReady': true};
            }
            expect(call.method, 'convert');
            expect(call.arguments, {
              'inputPath': 'book.epub',
              'outputPath': '/tmp/chapter-4',
              'chapterStart': 4,
              'chapterEnd': 4,
            });
            return jsonEncode({
              'audioPath': '/tmp/chapter-4/audio.mp3',
              'manifest': {
                'chapters': [
                  {'sourceIndex': 4, 'title': 'Chapter 4'},
                ],
              },
            });
          });

      final result = await AndroidEmbeddedConverter(channel: channel)
          .convertChapter(
            inputPath: 'book.epub',
            outputPath: '/tmp/chapter-4',
            chapterIndex: 4,
          );

      expect(result.chapterIndex, 4);
      expect(result.path, '/tmp/chapter-4/audio.mp3');
      expect(result.title, 'Chapter 4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test(
    'Android channel contract reports unavailable without native library',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'convert');
            expect(call.arguments, {
              'inputPath': 'book.epub',
              'outputPath': 'book.mp3',
            });
            throw PlatformException(
              code: 'EMBEDDED_CONVERTER_UNAVAILABLE',
              message:
                  'converter-ffi native library is not packaged in this APK',
            );
          });

      await expectLater(
        AndroidEmbeddedConverter(
          channel: channel,
        ).convert(inputPath: 'book.epub', outputPath: 'book.mp3'),
        throwsA(isA<EmbeddedConverterUnavailable>()),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test('Android parse channel reports typed unavailable error', () async {
    const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'parse');
          throw PlatformException(code: 'EMBEDDED_CONVERTER_UNAVAILABLE');
        });
    await expectLater(
      AndroidEmbeddedConverter(channel: channel).parse(inputPath: 'book.epub'),
      throwsA(isA<EmbeddedConverterUnavailable>()),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android channel exposes native runtime status', () async {
    const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'status');
          return <String, bool>{
            'runtimeLoaded': true,
            'modelAvailable': true,
            'abiCompatible': true,
            'engineReady': true,
          };
        });
    expect(
      await AndroidEmbeddedConverter(channel: channel).isRuntimeLoaded(),
      isTrue,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('embedded mode uses the registered implementation', () async {
    final embedded = FakeConverter();
    final adapter = LocalConverterAdapter(
      mode: ConverterMode.embedded,
      embedded: embedded,
      httpFallback: ({required inputPath, required outputPath}) async => 'http',
    );
    expect(
      await adapter.convert(inputPath: 'book.epub', outputPath: 'book.mp3'),
      'book.mp3',
    );
    expect(embedded.calls, 1);
  });

  test('embedded mode reports a typed unavailable error', () async {
    final adapter = LocalConverterAdapter(
      mode: ConverterMode.embedded,
      httpFallback: ({required inputPath, required outputPath}) async => 'http',
    );
    expect(
      () => adapter.convert(inputPath: 'book.epub', outputPath: 'book.mp3'),
      throwsA(isA<EmbeddedConverterUnavailable>()),
    );
  });

  test('HTTP mode explicitly uses the compatibility fallback', () async {
    var calls = 0;
    final adapter = LocalConverterAdapter(
      mode: ConverterMode.http,
      embedded: FakeConverter(),
      httpFallback: ({required inputPath, required outputPath}) async {
        calls++;
        return 'http-output';
      },
    );
    expect(
      await adapter.convert(inputPath: 'book.epub', outputPath: 'book.mp3'),
      'http-output',
    );
    expect(calls, 1);
  });

  test(
    'Android ABI contract uses the converter_ffi library name and typed error',
    () async {
      final source = File(
        'android/app/src/main/kotlin/com/pietrocode/epubtomp3/flutter_app/MainActivity.kt',
      ).readAsStringSync();
      expect(source, contains('System.loadLibrary(CONVERTER_LIBRARY)'));
      expect(
        source,
        contains('private const val CONVERTER_LIBRARY = "converter_ffi"'),
      );
      expect(source, contains('EMBEDDED_CONVERTER_UNAVAILABLE'));
      expect(source, contains('epub_to_mp3/embedded_converter'));
      expect(source, isNot(contains('httpFallback')));
    },
  );

  test('Android Piper synthesis forwards the captured options unchanged', () async {
    const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
    final options = const TtsPreferences().optionsJson(
      modelsRoot: '/models/pt_BR-faber-medium',
      language: 'pt-BR',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'piperSynthesize');
          expect(call.arguments, {
            'text': 'Olá, mundo.',
            'output': '/tmp/chapter.mp3',
            'optionsJson': options,
          });
          return '/tmp/chapter.mp3';
        });

    final result = await AndroidEmbeddedConverter(channel: channel).synthesizePiper(
      text: 'Olá, mundo.',
      output: '/tmp/chapter.mp3',
      optionsJson: options,
    );

    expect(result, '/tmp/chapter.mp3');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android Piper synthesis preserves native model errors', () async {
    const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'piperSynthesize');
          throw PlatformException(
            code: 'PIPER_MODEL_MISSING',
            message: 'Install the selected model before synthesis',
          );
        });

    await expectLater(
      AndroidEmbeddedConverter(channel: channel).synthesizePiper(
        text: 'Olá.',
        output: '/tmp/chapter.mp3',
        optionsJson: const TtsPreferences().optionsJson(
          modelsRoot: '/models',
          language: 'pt-BR',
        ),
      ),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'PIPER_MODEL_MISSING'),
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
