import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';

class FakeConverter implements EmbeddedConverter {
  int calls = 0;

  @override
  Future<EbookFulltext> parse({
    required String inputPath,
    String jobId = '',
  }) async => EbookFulltext.fromJson({'jobId': jobId, 'chapters': []});

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
  }) async {
    calls++;
    return outputPath;
  }

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
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
