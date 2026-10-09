import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/download_manager.dart';
import 'package:flutter_app/services/protected_audio_storage_guard.dart';

class _FileWritingDio implements Dio {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #download) {
      calls++;
      final path = invocation.positionalArguments[1] as String;
      return File(path)
          .writeAsString('downloaded audio')
          .then(
            (_) => Response<dynamic>(
              requestOptions: RequestOptions(path: '/audio'),
              statusCode: 200,
            ),
          );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;
  late _FileWritingDio dio;
  late DownloadManager manager;
  late int guardCalls;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('download-boundary-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => documents.path);
    dio = _FileWritingDio();
    guardCalls = 0;
    manager = DownloadManager(
      dio: dio,
      storageGuard: ProtectedAudioStorageGuard(
        availableBytes: () async {
          guardCalls++;
          return null;
        },
      ),
    );
  });

  tearDown(() async {
    manager.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await documents.delete(recursive: true);
  });

  for (final input in [
    (
      jobId: 'book',
      filename: '../private.mp3',
      victim: 'downloads/private.mp3',
    ),
    (
      jobId: '../private',
      filename: 'chapter.mp3',
      victim: 'private/chapter.mp3',
    ),
  ]) {
    test(
      'download cannot overwrite outside its job: ${input.jobId}/${input.filename}',
      () async {
        final victim = File('${documents.path}/${input.victim}');
        await victim.parent.create(recursive: true);
        await victim.writeAsString('protected file');
        Object? error;
        try {
          await manager.download(
            jobId: input.jobId,
            url: 'https://example.test/audio',
            filename: input.filename,
          );
        } catch (caught) {
          error = caught;
        }
        expect(await victim.readAsString(), 'protected file');
        expect(error, isA<ArgumentError>());
        expect(dio.calls, 0);
        expect(guardCalls, 0);
      },
    );
  }

  test(
    'invalid path components fail before storage or network access',
    () async {
      for (final value in [
        '',
        '.',
        '..',
        '../outside',
        r'..\outside',
        '/outside',
        r'C:\outside',
        '\u0000bad',
      ]) {
        await expectLater(
          manager.download(
            jobId: value,
            url: 'https://example.test/audio',
            filename: 'chapter.mp3',
          ),
          throwsArgumentError,
        );
        await expectLater(
          manager.download(
            jobId: 'book',
            url: 'https://example.test/audio',
            filename: value,
          ),
          throwsArgumentError,
        );
      }
      expect(guardCalls, 0);
      expect(dio.calls, 0);
      expect(await documents.list().toList(), isEmpty);
    },
  );

  test('single component with spaces still downloads normally', () async {
    final file = await manager.download(
      jobId: 'book-01',
      url: 'https://example.test/audio',
      filename: 'Chapter 1.mp3',
    );
    expect(file.path, '${documents.path}/downloads/book-01/Chapter 1.mp3');
    expect(await file.readAsString(), 'downloaded audio');
    expect(dio.calls, 1);
  });
}
