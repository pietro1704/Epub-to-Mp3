import 'dart:async';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/playback/audio_player_service.dart';
import 'package:flutter_app/services/playback/background_audio_handler.dart';
import 'package:flutter_app/services/playback/chapter_preparation.dart';
import 'package:flutter_app/services/playback/growing_chapter_audio_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import 'support/mock_just_audio_platform.dart';

// CAR-REMOTE-CHAPTERS: a car head unit sends plain next/previous to the MediaSession. They reach
// BackgroundAudioHandler.skipToNext/skipToPrevious, the REAL AudioPlayerService navigation and,
// for a chapter that is not queued yet, the session's chapter preparation.
ChapterProgress _completed(int index) => ChapterProgress(
  index: index,
  name: 'Chapter $index',
  status: 'completed',
  downloadUrl: Uri.file('/fixture/$index.mp3').toString(),
);

Future<void> _eventually(bool Function() condition, String failure) async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(failure);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AudioPlayerService player;
  late BackgroundAudioHandler handler;

  int? currentSource() {
    final index = player.currentIndexValue;
    return index == null
        ? null
        : player.chapters[player.chapterIndexForPlayerIndex(index)].index;
  }

  setUp(() {
    JustAudioPlatform.instance = MockJustAudioPlatform();
    player = AudioPlayerService(
      player: AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      ),
    )..currentBookId = 'book';
    handler = BackgroundAudioHandler(player);
  });

  tearDown(() async {
    await handler.dispose();
    await player.dispose();
  });

  test('next reaches the chapter still being synthesized without waiting for it to finish', () async {
    player.sourceChapterIndices = const [0, 1];
    await player.setQueue([_completed(0)]);
    await player.raw.load();
    await player.seek(const Duration(seconds: 12), index: 0);

    final preparation = ChapterPreparation();
    final growing = GrowingChapterAudioSource('/request-1');
    final prepared = <(int, bool)>[];
    player.onPrepareSourceChapter = (chapter, {required seekable}) {
      prepared.add((chapter, seekable));
      final ready = preparation.start(chapter, seekable: seekable);
      // What the playback session does when the converter starts the chapter.
      unawaited(
        Future<void>(() async {
          if (preparation.holdsStreaming(chapter)) return;
          player.registerGrowingChapter(chapter, growing);
          final running = ChapterProgress(
            index: chapter,
            name: 'Chapter $chapter',
            status: 'running',
            downloadUrl: Uri(
              scheme: 'growing',
              path: growing.requestId,
            ).toString(),
          );
          await player.setQueue([_completed(0), running]);
          preparation.queueUpdated([_completed(0), running]);
        }),
      );
      return ready;
    };

    await handler.skipToNext();
    await _eventually(
      () => currentSource() == 1,
      'next never reached chapter 1 (current: ${currentSource()}, queue: ${player.chapters.map((c) => c.index)})',
    );
    expect(
      growing.isComplete,
      isFalse,
      reason: 'the chapter is still synthesizing',
    );
    expect(prepared, [
      (1, false),
    ], reason: 'plain next does not need seekable audio');
  });

  test('a seek into a chapter that is not queued still waits for the finished chapter', () async {
    final preparation = ChapterPreparation();
    var resolved = false;
    final ready = preparation.start(3, seekable: true)
      ..then((_) => resolved = true);
    expect(preparation.holdsStreaming(3), isTrue);
    preparation.queueUpdated([
      ChapterProgress(
        index: 3,
        name: 'Chapter 3',
        status: 'running',
        downloadUrl: 'growing:/request-3',
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);
    preparation.queueUpdated([_completed(3)]);
    expect(await ready, isTrue);
  });

  test('previous from the middle of a chapter lands on the start of the previous chapter', () async {
    player.sourceChapterIndices = const [0, 1, 2];
    await player.setQueue([_completed(0), _completed(1), _completed(2)]);
    await player.raw.load();
    await player.seek(const Duration(seconds: 20), index: 1);
    expect(currentSource(), 1);

    await handler.skipToPrevious();
    await _eventually(
      () => currentSource() == 0,
      'previous did not leave chapter 1 (current: ${currentSource()})',
    );
    expect(player.positionSeconds, 0);
  });
}
