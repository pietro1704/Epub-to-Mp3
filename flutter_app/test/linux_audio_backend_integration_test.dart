import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/desktop_audio_backend.dart';

Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

Future<File> fixture(Directory directory) async {
  const rate = 24000;
  final bytes = ByteData(44 + rate * 2 * 4);
  void text(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, bytes.lengthInBytes - 44, Endian.little);
  for (var index = 0; index < rate * 4; index++) {
    bytes.setInt16(
      44 + index * 2,
      (sin(2 * pi * 440 * index / rate) * 4096).round(),
      Endian.little,
    );
  }
  return File(
    '${directory.path}/fixture.wav',
  ).writeAsBytes(bytes.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Linux decoder plays, pauses, resumes, completes and rejects a replacement',
    () async {
      if (!const bool.fromEnvironment('EPUB2MP3_SKIP_BACKEND_INIT')) {
        initializeDesktopAudioBackend(TargetPlatform.linux);
      }
      final directory = await Directory.systemTemp.createTemp('epub-decoder-');
      final player = AudioPlayerService();
      addTearDown(() async {
        await player.dispose();
        await directory.delete(recursive: true);
      });
      final valid = await fixture(directory);
      await player.setQueue([
        ChapterProgress(
          index: 16,
          name: 'Source',
          downloadUrl: valid.uri.toString(),
        ),
      ]);
      final duration = await player.raw.load();
      expect(duration?.inMilliseconds, inInclusiveRange(3990, 4010));
      expect(player.isPlaying, isFalse);
      expect(player.chapters[player.chapterIndexForPlayerIndex(0)].index, 16);
      final playback = player.play();
      await eventually(() => player.isPlaying && player.positionSeconds > 0.2);
      await player.pause();
      await eventually(() => player.phase == PlaybackPhase.paused);
      final paused = player.positionSeconds;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.positionSeconds, closeTo(paused, 0.1));
      final resumed = player.play();
      await eventually(() => player.positionSeconds > paused + 0.2);
      await eventually(() => player.phase == PlaybackPhase.completed);
      expect(player.isPlaying, isFalse);
      await Future.wait([playback, resumed]);
      final restarted = player.play();
      await eventually(() => player.isPlaying && player.positionSeconds < 2);
      await player.pause();
      await restarted;

      final invalid = await File(
        '${directory.path}/invalid.mp3',
      ).writeAsString('not encoded audio');
      await player.setQueue([
        ChapterProgress(
          index: 24,
          name: 'Replacement',
          downloadUrl: invalid.uri.toString(),
        ),
      ]);
      expect(player.chapters[player.chapterIndexForPlayerIndex(0)].index, 24);
      // The backend reports decode errors through its event stream.
      unawaited(player.play().catchError((Object _) {}));
      await eventually(() => player.phase == PlaybackPhase.failed);
      expect(player.isPlaying, isFalse);
      await player.setQueue([
        ChapterProgress(
          index: 31,
          name: 'Recovery',
          downloadUrl: valid.uri.toString(),
        ),
      ]);
      await player.raw.load();
      expect(player.chapters[player.chapterIndexForPlayerIndex(0)].index, 31);
      final recovery = player.play();
      await eventually(() => player.isPlaying && player.positionSeconds > 0.2);
      await player.pause();
      await recovery;
    },
    skip:
        !Platform.isLinux ||
        !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'),
  );
}
