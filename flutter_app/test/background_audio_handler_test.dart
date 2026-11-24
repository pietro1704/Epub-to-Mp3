import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/models/app_settings.dart';

import 'support/fake_audio_player_service.dart';

import 'package:flutter_app/services/playback/background_audio_handler.dart';

void main() {
  group('BackgroundAudioMetadataMapper', () {
    test('maps book, chapter, cover and duration to MediaItem', () {
      final item = BackgroundAudioMetadataMapper.toMediaItem(
        const BackgroundAudioMetadata(
          bookId: 'book-1',
          bookTitle: 'The Book',
          author: 'Author',
          chapterTitle: 'Chapter 2',
          coverArtUri: 'https://example.test/cover.jpg',
          duration: Duration(minutes: 12),
        ),
      );

      expect(item.id, 'book-1:chapter-2');
      expect(item.title, 'Chapter 2');
      expect(item.album, 'The Book');
      expect(item.artist, 'Author');
      expect(item.artUri, Uri.parse('https://example.test/cover.jpg'));
      expect(item.duration, const Duration(minutes: 12));
    });

    test('uses book title when chapter title is absent', () {
      final item = BackgroundAudioMetadataMapper.toMediaItem(
        const BackgroundAudioMetadata(bookId: 'book-1', bookTitle: 'The Book'),
      );
      expect(item.id, 'book-1:book');
      expect(item.title, 'The Book');
      expect(item.album, 'The Book');
    });
  });

  group('BackgroundAudioHandler', () {
    late FakeAudioPlayerService player;
    late BackgroundAudioHandler handler;

    setUp(() {
      player = FakeAudioPlayerService();
      handler = BackgroundAudioHandler(player);
    });

    tearDown(() => handler.dispose());

    test('maps media commands to the existing AudioPlayerInterface', () async {
      await handler.play();
      expect(player.isPlaying, isTrue);
      await handler.pause();
      expect(player.isPlaying, isFalse);

      await handler.seek(const Duration(seconds: 7));
      expect(player.positionSeconds, 7);
      await handler.setSpeed(1.5);
      expect(player.speed, 1.5);
    });

    test(
      'maps skip and chapter commands without replacing player logic',
      () async {
        await handler.skipToNext();
        await handler.skipToPrevious();
        await handler.fastForward();
        expect(player.positionSeconds, 15);
        await handler.rewind();
        expect(player.positionSeconds, 0);
      },
    );

    test('publishes metadata and playback state from the player', () async {
      await handler.setMetadata(
        const BackgroundAudioMetadata(
          bookId: 'book-1',
          bookTitle: 'The Book',
          chapterTitle: 'Chapter 1',
          duration: Duration(seconds: 42),
        ),
      );
      expect(handler.mediaItem.value?.title, 'Chapter 1');
      expect(handler.mediaItem.value?.duration, const Duration(seconds: 42));

      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(handler.playbackState.value.speed, 1.0);
    });

    group('external next/previous buttons (REMOTE-BUTTON-MODE)', () {
      // Car head units, headphones, the lock screen and the notification all send
      // skipToNext / skipToPrevious.
      test('default: they go to the next / previous chapter', () async {
        expect(handler.remoteButtonMode, RemoteButtonMode.chapter);
        await player.setQueue([
          const ChapterProgress(
            index: 0,
            name: 'One',
            status: 'completed',
            downloadUrl: 'file:///a.mp3',
          ),
          const ChapterProgress(
            index: 1,
            name: 'Two',
            status: 'completed',
            downloadUrl: 'file:///b.mp3',
          ),
        ]);
        final before = player.currentIndexValue;
        await handler.skipToNext();
        expect(player.currentIndexValue, (before ?? 0) + 1);
        await handler.skipToPrevious();
        expect(player.currentIndexValue, before);
        expect(player.positionSeconds, 0, reason: 'no seconds were skipped');
      });

      test(
        'skip mode: next / previous skip the configured forward / back seconds',
        () async {
          player.seekForwardSeconds = 45;
          player.seekBackwardSeconds = 30;
          handler.remoteButtonMode = RemoteButtonMode.seconds;
          await player.seek(const Duration(seconds: 100));
          final chapter = player.currentIndexValue;
          await handler.skipToNext();
          expect(player.positionSeconds, 145);
          await handler.skipToPrevious();
          expect(player.positionSeconds, 115);
          expect(
            player.currentIndexValue,
            chapter,
            reason: 'the chapter did not change',
          );
        },
      );

      test('the published controls follow the mode', () async {
        List<MediaAction> actions() =>
            handler.playbackState.value.systemActions.toList();
        expect(
          handler.playbackState.value.controls.map((c) => c.action),
          containsAll([MediaAction.skipToPrevious, MediaAction.skipToNext]),
        );
        handler.remoteButtonMode = RemoteButtonMode.seconds;
        final controls = handler.playbackState.value.controls
            .map((c) => c.action)
            .toList();
        expect(
          controls,
          containsAll([MediaAction.rewind, MediaAction.fastForward]),
        );
        expect(controls, isNot(contains(MediaAction.skipToNext)));
        expect(controls, isNot(contains(MediaAction.skipToPrevious)));
        expect(
          actions(),
          containsAll([MediaAction.seekForward, MediaAction.seekBackward]),
        );
        // A head unit that only knows track commands still gets the seconds behaviour above.
      });
    });
  });
}
