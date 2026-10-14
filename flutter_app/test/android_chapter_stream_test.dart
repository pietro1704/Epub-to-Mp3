import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/embedded_converter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancellation during stream handshake never starts JNI conversion',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      final events = StreamController<dynamic>.broadcast();
      final handshake = Completer<bool>();
      final waiting = Completer<void>();
      var conversions = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'status') return {'engineReady': true};
            if (call.method == 'cancelConversion') return null;
            if (call.method == 'streamReady') {
              waiting.complete();
              return handshake.future;
            }
            conversions++;
            return null;
          });
      final converter = AndroidEmbeddedConverter(
        channel: channel,
        chunkEvents: events.stream,
      );
      final conversion = converter.streamChapter(
        inputPath: '/book.epub',
        outputPath: '/request-unique',
        chapterIndex: 4,
        onFirstAudio: (_) async {
          fail('Cancelled request delivered audio');
        },
      );
      final failure = expectLater(conversion, throwsStateError);
      await waiting.future;
      await converter.cancelStreamingChapter('/request-unique');
      handshake.complete(true);
      await failure;
      expect(conversions, 0);
      await events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  test(
    'request-scoped chunk reaches reader before final chapter result',
    () async {
      const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
      final root = await Directory.systemTemp.createTemp('android-stream-');
      final chunk = File('${root.path}/0.mp3')..writeAsBytesSync([1, 2, 3]);
      final events = StreamController<dynamic>.broadcast(sync: true);
      final result = Completer<String>();
      final started = Completer<void>();
      final firstAudio = Completer<void>();
      final converter = AndroidEmbeddedConverter(
        channel: channel,
        chunkEvents: events.stream,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'status') return {'engineReady': true};
            if (call.method == 'streamReady') return true;
            expect(call.method, 'convert');
            expect((call.arguments as Map)['streaming'], true);
            started.complete();
            return result.future;
          });
      var completed = false;
      final conversion = converter
          .streamChapter(
            inputPath: '/book.epub',
            outputPath: root.path,
            chapterIndex: 4,
            onFirstAudio: (source) async {
              final response = await source.request();
              expect(await response.stream.first, [1, 2, 3]);
              expect(source.isComplete, false);
              firstAudio.complete();
            },
          )
          .then((value) {
            completed = true;
            return value;
          });
      await started.future;
      events.add({
        'requestId': 'stale',
        'chapterIndex': 4,
        'chunkIndex': 0,
        'path': chunk.path,
      });
      events.add({
        'requestId': root.path,
        'chapterIndex': 5,
        'chunkIndex': 0,
        'path': chunk.path,
      });
      events.add({
        'requestId': root.path,
        'chapterIndex': 4,
        'chunkIndex': 0,
        'path': chunk.path,
      });
      await firstAudio.future;
      expect(completed, false);
      events.add({
        'requestId': root.path,
        'chapterIndex': 4,
        'chunkIndex': 0,
        'path': chunk.path,
      });
      result.complete(
        jsonEncode({
          'audioPath': chunk.path,
          'manifest': {
            'chapters': [
              {'sourceIndex': 4, 'title': 'Chapter4'},
            ],
          },
        }),
      );
      expect((await conversion).chapterIndex, 4);
      events.add({
        'requestId': root.path,
        'chapterIndex': 4,
        'chunkIndex': 1,
        'path': '/late.mp3',
      });
      await events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    },
  );
}
