import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/download_manager.dart';
import 'package:flutter_app/services/protected_audio_storage_guard.dart';

class _DownloadDio implements Dio {
  _DownloadDio(this.downloadFile);
  final Future<Response<dynamic>> Function(String, CancelToken) downloadFile;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #download) {
      return downloadFile(
        invocation.positionalArguments[1] as String,
        invocation.namedArguments[#cancelToken] as CancelToken,
      );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('download-manager-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => documents.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await documents.delete(recursive: true);
  });

  Future<File> existingAudio() async {
    final file = File('${documents.path}/downloads/book/chapter.mp3');
    await file.parent.create(recursive: true);
    await file.writeAsString('complete previous audio');
    return file;
  }

  DownloadManager managerWith(_DownloadDio dio) => DownloadManager(
    dio: dio,
    storageGuard: ProtectedAudioStorageGuard(availableBytes: () async => null),
  );

  for (final failure in [
    DioExceptionType.connectionError,
    DioExceptionType.cancel,
  ]) {
    test('failed download preserves previous audio: ${failure.name}', () async {
      final audio = await existingAudio();
      final manager = managerWith(
        _DownloadDio((path, _) async {
          await File(path).writeAsString('partial replacement');
          throw DioException(
            requestOptions: RequestOptions(path: '/audio'),
            type: failure,
          );
        }),
      );
      addTearDown(manager.dispose);
      await expectLater(
        manager.download(
          jobId: 'book',
          url: 'https://example.test/audio',
          filename: 'chapter.mp3',
        ),
        throwsA(isA<DioException>()),
      );
      expect(
        await audio.exists(),
        isTrue,
        reason: 'completed offline audio must survive failed replacement',
      );
      expect(await audio.readAsString(), 'complete previous audio');
      expect(await audio.parent.list().map((entry) => entry.path).toList(), [
        audio.path,
      ]);
    });
  }

  test(
    'replacement remains private until complete and then publishes',
    () async {
      final audio = await existingAudio();
      final received = Completer<void>();
      final finish = Completer<void>();
      final manager = managerWith(
        _DownloadDio((path, _) async {
          await File(path).writeAsString('complete replacement audio');
          received.complete();
          await finish.future;
          return Response<dynamic>(
            requestOptions: RequestOptions(path: '/audio'),
            statusCode: 200,
          );
        }),
      );
      addTearDown(manager.dispose);
      final pending = manager.download(
        jobId: 'book',
        url: 'https://example.test/audio',
        filename: 'chapter.mp3',
      );
      await received.future;
      try {
        expect(await audio.readAsString(), 'complete previous audio');
      } finally {
        finish.complete();
        await pending;
      }
      expect(await audio.readAsString(), 'complete replacement audio');
      expect(
        await audio.parent.list().where((entry) => entry is Directory).toList(),
        isEmpty,
      );
    },
  );

  test(
    'disposing a partial replacement preserves completed offline audio',
    () async {
      final audio = await existingAudio();
      final started = Completer<void>();
      final manager = managerWith(
        _DownloadDio((path, token) async {
          await File(path).writeAsString('partial replacement');
          started.complete();
          throw await token.whenCancel;
        }),
      );
      addTearDown(manager.dispose);
      final outcome = manager
          .download(
            jobId: 'book',
            url: 'https://example.test/audio',
            filename: 'chapter.mp3',
          )
          .then<Object>(
            (file) => file,
            onError: (Object error, StackTrace _) => error,
          );
      await started.future;
      manager.dispose();
      expect(
        await outcome.timeout(const Duration(seconds: 2)),
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      );
      expect(await audio.exists(), isTrue);
      expect(await audio.readAsString(), 'complete previous audio');
      expect(await audio.parent.list().map((entry) => entry.path).toList(), [
        audio.path,
      ]);
    },
  );

  group('DownloadEvent', () {
    test('completed event has no error', () {
      const ev = DownloadEvent(path: '/a.mp3', progress: 1.0, completed: true);
      expect(ev.completed, isTrue);
      expect(ev.error, isNull);
    });

    test('error event carries message', () {
      const ev = DownloadEvent(path: '/a.mp3', progress: 0, error: 'timeout');
      expect(ev.completed, isFalse);
      expect(ev.error, 'timeout');
    });

    test('progress event mid-download', () {
      const ev = DownloadEvent(path: '/a.mp3', progress: 0.5);
      expect(ev.completed, isFalse);
      expect(ev.error, isNull);
      expect(ev.progress, 0.5);
    });
  });

  group('DownloadManager', () {
    test('events stream is broadcast', () {
      final dm = DownloadManager();
      final s1 = dm.events.listen((_) {});
      final s2 = dm.events.listen((_) {});
      s1.cancel();
      s2.cancel();
      dm.dispose();
    });
  });
}
