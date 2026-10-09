import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/download_manager.dart';
import 'package:flutter_app/services/protected_audio_storage_guard.dart';

class _PendingDownloadDio implements Dio {
  final started = Completer<void>();
  final twoStarted = Completer<void>();
  final tokens = <CancelToken>[];
  late CancelToken token;
  late void Function(int, int) progress;
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #download) {
      calls++;
      token = invocation.namedArguments[#cancelToken] as CancelToken;
      progress =
          invocation.namedArguments[#onReceiveProgress]
              as void Function(int, int);
      tokens.add(token);
      if (!started.isCompleted) started.complete();
      if (calls == 2) twoStarted.complete();
      return token.whenCancel.then<Response<dynamic>>((error) => throw error);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;
  late _PendingDownloadDio dio;
  late DownloadManager manager;
  late int storageCalls;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('download-disposal-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => documents.path);
    dio = _PendingDownloadDio();
    storageCalls = 0;
    manager = DownloadManager(
      dio: dio,
      storageGuard: ProtectedAudioStorageGuard(
        availableBytes: () async {
          storageCalls++;
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

  test(
    'dispose cancels an active transfer and preserves cancellation errors',
    () async {
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
      await dio.started.future;
      manager.dispose();
      try {
        expect(dio.token.isCancelled, isTrue);
        expect(
          await outcome,
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        );
      } finally {
        dio.token.cancel();
        await outcome;
      }
    },
  );

  for (final stop in ['cancel', 'dispose']) {
    test('$stop stops every concurrent transfer for the same path', () async {
      final outcomes = List.generate(
        2,
        (_) => manager
            .download(
              jobId: 'book',
              url: 'https://example.test/audio',
              filename: 'chapter.mp3',
            )
            .then<Object>(
              (file) => file,
              onError: (Object error, StackTrace _) => error,
            ),
      );
      await dio.twoStarted.future;
      try {
        if (stop == 'dispose') {
          manager.dispose();
        } else {
          manager.cancel('${documents.path}/downloads/book/chapter.mp3');
        }
        expect(dio.tokens.every((token) => token.isCancelled), isTrue);
        final results = await Future.wait(
          outcomes,
        ).timeout(const Duration(seconds: 2));
        expect(
          results,
          everyElement(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        final folder = Directory('${documents.path}/downloads/book');
        expect(
          await folder.list().where((entry) => entry is Directory).toList(),
          isEmpty,
        );
      } finally {
        for (final token in dio.tokens) {
          token.cancel();
        }
        await Future.wait(outcomes);
      }
    });
  }

  test('late progress does not emit into a closed event stream', () async {
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
    await dio.started.future;
    manager.dispose();
    try {
      expect(() => dio.progress(1, 2), returnsNormally);
    } finally {
      dio.token.cancel();
      await outcome;
    }
  });

  test(
    'disposal during storage check prevents the transfer from starting',
    () async {
      final checking = Completer<void>();
      final available = Completer<int?>();
      final delayed = DownloadManager(
        dio: dio,
        storageGuard: ProtectedAudioStorageGuard(
          availableBytes: () {
            checking.complete();
            return available.future;
          },
        ),
      );
      final outcome = delayed
          .download(
            jobId: 'book',
            url: 'https://example.test/audio',
            filename: 'chapter.mp3',
          )
          .then<Object>(
            (file) => file,
            onError: (Object error, StackTrace _) => error,
          );
      await checking.future;
      delayed.dispose();
      available.complete(null);
      expect(await outcome, isA<StateError>());
      expect(dio.calls, 0);
    },
  );

  test(
    'disposed manager rejects new transfers before accessing storage',
    () async {
      manager.dispose();
      await expectLater(
        manager.download(
          jobId: 'book',
          url: 'https://example.test/audio',
          filename: 'chapter.mp3',
        ),
        throwsStateError,
      );
      expect(storageCalls, 0);
      expect(dio.calls, 0);
      expect(await documents.list().toList(), isEmpty);
    },
  );
}
