import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/growing_chapter_audio_source.dart';

void main() {
  test(
    'delivers first bytes before completion and waits for appended chunks',
    () async {
      final root = await Directory.systemTemp.createTemp('growing-audio-');
      final first = File('${root.path}/0.mp3')..writeAsBytesSync([1, 2]);
      final second = File('${root.path}/1.mp3')..writeAsBytesSync([3, 4]);
      final source = GrowingChapterAudioSource('request');
      final response = await source.request();
      expect(response.rangeRequestsSupported, false);
      expect(response.contentLength, null);
      final bytes = <int>[];
      final received = Completer<void>();
      var ended = false;
      final subscription = response.stream.listen(
        (chunk) {
          bytes.addAll(chunk);
          if (!received.isCompleted) received.complete();
        },
        onDone: () {
          ended = true;
        },
      );
      await source.append(0, first.path);
      await received.future;
      expect(bytes, [1, 2]);
      expect(ended, false);
      expect(source.isComplete, false);
      await source.append(0, first.path);
      await source.append(1, second.path);
      source.complete();
      await subscription.asFuture<void>();
      expect(bytes, [1, 2, 3, 4]);
      await source.append(2, first.path);
      expect(source.chunkCount, 2);
      final range = await source.request(1, 3);
      expect(range.rangeRequestsSupported, true);
      expect(range.contentLength, 2);
      expect(await range.stream.expand((bytes) => bytes).toList(), [2, 3]);
      await root.delete(recursive: true);
    },
  );

  test(
    'seek waits for final length and cancellation wakes active readers',
    () async {
      final source = GrowingChapterAudioSource('request');
      var seekReady = false;
      final seek = source.request(1).then((_) {
        seekReady = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(seekReady, false);
      final response = await source.request();
      final read = response.stream.toList();
      final readError = expectLater(read, throwsStateError);
      final seekError = expectLater(seek, throwsStateError);
      source.fail(StateError('cancelled'));
      await readError;
      await seekError;
    },
  );

  test(
    'rejects missing ordered chunks instead of silently dropping text',
    () async {
      final source = GrowingChapterAudioSource('request');
      await expectLater(source.append(1, '/not-opened.mp3'), throwsStateError);
      source.complete();
    },
  );
}
