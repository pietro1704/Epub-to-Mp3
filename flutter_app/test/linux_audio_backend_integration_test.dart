import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/playback/audio_player_service.dart';
import 'package:flutter_app/services/playback/desktop_audio_backend.dart';
import 'package:flutter_app/services/playback/growing_chapter_audio_source.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

class _ObservedGrowingSource extends GrowingChapterAudioSource {
  _ObservedGrowingSource() : super('slow-chapter');

  final firstRequest = Completer<void>();

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) {
    if (!firstRequest.isCompleted) firstRequest.complete();
    return super.request(start, end);
  }
}

Future<void> eventually(
  bool Function() condition, {
  String Function()? failure,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: failure?.call());
}

Future<File> fixture(
  Directory directory, {
  String name = 'fixture',
  int seconds = 4,
}) async {
  const rate = 24000;
  final bytes = ByteData(44 + rate * 2 * seconds);
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
  for (var index = 0; index < rate * seconds; index++) {
    bytes.setInt16(
      44 + index * 2,
      (sin(2 * pi * 440 * index / rate) * 4096).round(),
      Endian.little,
    );
  }
  return File('${directory.path}/$name.wav')
      .writeAsBytes(bytes.buffer.asUint8List());
}

Future<File> growingMp3Fixture(Directory directory) async {
  final frames = await File(
    '../tests/fixtures/audio/mono-24000-48k.mp3',
  ).readAsBytes();
  // 32 copies of a 312 ms CBR fixture with no metadata or duration header.
  return File('${directory.path}/chunk.mp3').writeAsBytes([
    for (var copy = 0; copy < 32; copy++) ...frames,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native decoder keeps reading across a 21.5 second chapter synthesis gap',
    () async {
      if (Platform.isWindows) {
        initializeDesktopAudioBackend(TargetPlatform.windows);
      } else {
        // Exercise the Windows network timeout on the host decoder.
        JustAudioMediaKit.ensureInitialized(
          networkTimeout: const Duration(seconds: 60),
        );
      }
      final directory = await Directory.systemTemp.createTemp('epub-slow-');
      final player = AudioPlayerService();
      final source = _ObservedGrowingSource();
      addTearDown(() async {
        source.complete();
        await player.dispose();
        await directory.delete(recursive: true);
      });
      final chunk = await growingMp3Fixture(directory);
      await source.append(0, chunk.path);
      player.registerGrowingChapter(0, source);
      await player.setQueue([
        const ChapterProgress(
          index: 0,
          name: 'Slow chapter',
          downloadUrl: 'growing:slow-chapter',
        ),
      ]);
      await player.setSpeed(2);
      final playback = player.play();
      await source.firstRequest.future.timeout(const Duration(seconds: 10));
      final deliveryDelay = Future<void>.delayed(
        const Duration(milliseconds: 21500),
      );
      await eventually(() => player.isPlaying && player.positionSeconds > 0.2);
      await deliveryDelay;
      expect(source.isComplete, isFalse);
      expect(
        player.phase,
        isNot(anyOf(PlaybackPhase.completed, PlaybackPhase.failed)),
      );
      await source.append(1, chunk.path);
      source.complete();
      await eventually(
        () => player.positionSeconds > 18,
        failure: () => 'Stopped at ${player.positionSeconds}s (${player.phase})',
      );
      await player.pause();
      await playback;
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip:
        !(Platform.isLinux || Platform.isWindows) ||
        !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'),
  );

  test(
    'Linux decoder completes when a buffering chapter reaches EOF',
    () async {
      // Keep the network timeout well outside the completion assertion.
      JustAudioMediaKit.ensureInitialized(
        networkTimeout: const Duration(seconds: 30),
      );
      final directory = await Directory.systemTemp.createTemp('epub-eof-');
      final player = AudioPlayerService();
      final source = _ObservedGrowingSource();
      addTearDown(() async {
        source.complete();
        await player.dispose();
        await directory.delete(recursive: true);
      });
      await source.append(0, (await growingMp3Fixture(directory)).path);
      player.registerGrowingChapter(0, source);
      await player.setQueue([
        const ChapterProgress(
          index: 0,
          name: 'Final chunk',
          downloadUrl: 'growing:slow-chapter',
        ),
      ]);
      await player.setSpeed(2);
      final playback = player.play();
      await eventually(() => player.isPlaying && player.positionSeconds > 0.2);
      await eventually(() => player.phase == PlaybackPhase.buffering);

      final completed = player.phases
          .firstWhere((phase) => phase == PlaybackPhase.completed)
          .timeout(const Duration(seconds: 3));
      source.complete();
      await completed;
      await playback;
    },
    skip:
        !Platform.isLinux ||
        !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'),
  );

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

      final invalid = await File('${directory.path}/invalid.mp3')
          .writeAsString('not encoded audio');
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
  test(
    'seeks past the live response using a completed desktop chapter',
    () async {
      initializeDesktopAudioBackend(TargetPlatform.linux);
      final directory = await Directory.systemTemp.createTemp('epub-live-seek-');
      final player = AudioPlayerService();
      addTearDown(() async {
        await player.dispose();
        await directory.delete(recursive: true);
      });
      final finished = await fixture(directory, seconds: 28);
      final bytes = await finished.readAsBytes();
      const split = 9 * 24000 * 2 + 44;
      final first = await File(
        '${directory.path}/first',
      ).writeAsBytes(bytes.sublist(0, split));
      final rest = await File(
        '${directory.path}/rest',
      ).writeAsBytes(bytes.sublist(split));
      final source = GrowingChapterAudioSource('live-seek');
      await source.append(0, first.path);
      player.registerGrowingChapter(0, source);
      await player.setQueue([
        const ChapterProgress(
          index: 0,
          name: 'Growing',
          downloadUrl: 'growing:live-seek',
        ),
      ]);
      final playing = player.play();
      await eventually(() => player.isPlaying && player.positionSeconds > 0.2);
      await player.pause();
      await playing;
      final pausedAt = player.positionSeconds;
      player.skipForward(seconds: 15);
      await source.append(1, rest.path);
      source.complete(completedPath: finished.path);
      await eventually(
        () => (player.positionSeconds - pausedAt - 15).abs() < 0.25,
      );
      final localSource = player.raw.sequence.single as UriAudioSource;
      expect(localSource.uri, finished.uri);
      expect(player.isPlaying, isFalse);
    },
    skip:
        !Platform.isLinux ||
        !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'),
  );
  test(
    'relative skips carry their full offset over short and on-demand chapters',
    () async {
      initializeDesktopAudioBackend(TargetPlatform.linux);
      final directory = await Directory.systemTemp.createTemp('epub-seek-');
      final player = AudioPlayerService();
      addTearDown(() async {
        await player.dispose();
        await directory.delete(recursive: true);
      });
      final entries = [
        for (final (index, duration) in [(4, 80), (9, 5), (11, 80)])
          ChapterProgress(
            index: index,
            name: 'Chapter $index',
            downloadUrl: (await fixture(
              directory,
              name: '$index',
              seconds: duration,
            )).uri.toString(),
          ),
      ];
      await player.setQueue([entries.first]);
      await player.raw.load();
      player.sourceChapterIndices = [4, 9, 11];
      final preparations = <int>[];
      player.onPrepareSourceChapter = (chapter, {required seekable}) async {
        preparations.add(chapter);
        final count = entries.indexWhere((entry) => entry.index == chapter) + 1;
        await player.setQueue(entries.take(count).toList());
        return true;
      };
      Future<void> at(int source, double seconds) async {
        await eventually(
          () {
            final index = player.currentIndexValue;
            return index != null &&
                player
                        .chapters[player.chapterIndexForPlayerIndex(index)]
                        .index ==
                    source &&
                (player.positionSeconds - seconds).abs() < 0.25;
          },
          failure: () =>
              'Expected source $source at ${seconds}s, received ${player.raw.playbackEvent}',
        );
        expect(player.isPlaying, isFalse);
      }

      for (final interval in [15, 30, 60]) {
        await player.seek(const Duration(seconds: 77), index: 0);
        await at(4, 77);
        player.seekForwardSeconds = interval;
        player.skipForward();
        await at(11, (interval - 8).toDouble());

        await player.seek(const Duration(seconds: 3), index: 2);
        await at(11, 3);
        player.seekBackwardSeconds = interval;
        player.skipBackward();
        await at(4, (88 - interval).toDouble());
      }
      expect(preparations, [9, 11]);
      await player.seek(const Duration(seconds: 2), index: 0);
      player.skipBackward();
      await at(4, 0);
      await player.seek(const Duration(seconds: 78), index: 2);
      player.skipForward();
      await at(11, 80);
    },
    skip:
        !Platform.isLinux ||
        !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'),
  );
}
