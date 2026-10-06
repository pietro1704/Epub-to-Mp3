import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/background_audio_handler.dart';

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

    test('maps skip and chapter commands without replacing player logic', () async {
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.fastForward();
      expect(player.positionSeconds, 15);
      await handler.rewind();
      expect(player.positionSeconds, 0);
    });

    test('publishes metadata and playback state from the player', () async {
      await handler.setMetadata(const BackgroundAudioMetadata(
        bookId: 'book-1',
        bookTitle: 'The Book',
        chapterTitle: 'Chapter 1',
        duration: Duration(seconds: 42),
      ));
      expect(handler.mediaItem.value?.title, 'Chapter 1');
      expect(handler.mediaItem.value?.duration, const Duration(seconds: 42));

      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(handler.playbackState.value.speed, 1.0);
    });
  });
}
