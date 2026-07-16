import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'audio_player_service.dart';
import 'widget_playback_snapshot.dart';

/// Metadata shared by the Flutter player and Android MediaSession.
class BackgroundAudioMetadata {
  const BackgroundAudioMetadata({
    required this.bookId,
    required this.bookTitle,
    this.author,
    this.chapterTitle,
    this.chapterIndex,
    this.coverArtUri,
    this.duration,
  });

  final String bookId;
  final String bookTitle;
  final String? author;
  final String? chapterTitle;
  final int? chapterIndex;
  final String? coverArtUri;
  final Duration? duration;
}

/// Pure mapping code kept separate so it can be tested on the host platform.
class BackgroundAudioMetadataMapper {
  static MediaItem toMediaItem(BackgroundAudioMetadata metadata) {
    final chapterLabel = metadata.chapterTitle?.trim();
    final hasChapter = chapterLabel != null && chapterLabel.isNotEmpty;
    final chapterKey = metadata.chapterIndex != null
        ? 'chapter-${metadata.chapterIndex}'
        : hasChapter
        ? chapterLabel.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        : 'book';
    return MediaItem(
      id: '${metadata.bookId}:$chapterKey',
      title: hasChapter ? chapterLabel : metadata.bookTitle,
      album: metadata.bookTitle,
      artist: metadata.author,
      artUri: _parseUri(metadata.coverArtUri),
      duration: metadata.duration,
      extras: <String, dynamic>{
        'bookId': metadata.bookId,
        if (metadata.chapterIndex != null)
          'chapterIndex': metadata.chapterIndex,
      },
    );
  }

  static Uri? _parseUri(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return Uri.tryParse(value);
  }
}

/// AudioService adapter over the existing player abstraction.
///
/// It deliberately delegates transport and queue behaviour to
/// [AudioPlayerInterface], preserving the desktop/iOS implementation and its
/// fake test double.
class BackgroundAudioHandler extends BaseAudioHandler {
  BackgroundAudioHandler(
    this.player, {
    WidgetPlaybackSnapshotStore? snapshotStore,
  }) : _snapshotStore = snapshotStore {
    _subscriptions.add(player.playing.listen((_) => _publishState()));
    _subscriptions.add(player.position.listen((_) => _publishState()));
    _subscriptions.add(player.currentIndex.listen((_) => _publishState()));
    _publishState();
  }

  final AudioPlayerInterface player;
  final WidgetPlaybackSnapshotStore? _snapshotStore;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  String? _lastMetadataId;
  BackgroundAudioMetadata? _metadata;

  Future<void> setMetadata(BackgroundAudioMetadata metadata) async {
    _metadata = metadata;
    final item = BackgroundAudioMetadataMapper.toMediaItem(metadata);
    if (_lastMetadataId == item.id && mediaItem.value == item) return;
    _lastMetadataId = item.id;
    mediaItem.add(item);
    _publishState(duration: metadata.duration);
  }

  @override
  Future<void> play() async {
    await player.play();
    _publishState();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    _publishState();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    _publishState();
  }

  @override
  Future<void> fastForward() async {
    player.skipForward();
    _publishState();
  }

  @override
  Future<void> rewind() async {
    player.skipBackward();
    _publishState();
  }

  @override
  Future<void> skipToNext() async {
    player.nextChapter();
    _publishState();
  }

  @override
  Future<void> skipToPrevious() async {
    player.previousChapter();
    _publishState();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await player.setSpeed(speed);
    _publishState();
  }

  @override
  Future<void> stop() async {
    await player.pause();
    await player.seek(Duration.zero);
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        updatePosition: Duration.zero,
      ),
    );
  }

  void _publishState({Duration? duration}) {
    if (_disposed) return;
    final currentDuration =
        duration ??
        (player.durationSeconds > 0
            ? Duration(milliseconds: (player.durationSeconds * 1000).round())
            : mediaItem.value?.duration);
    final state = PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        player.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: player.isPlaying || currentDuration != null
          ? AudioProcessingState.ready
          : AudioProcessingState.idle,
      playing: player.isPlaying,
      updatePosition: Duration(
        milliseconds: (player.positionSeconds * 1000).round(),
      ),
      bufferedPosition: Duration.zero,
      speed: player.speed,
      queueIndex: player.currentIndexValue,
    );
    playbackState.add(state);
    if (currentDuration != null && mediaItem.value != null) {
      mediaItem.add(mediaItem.value!.copyWith(duration: currentDuration));
    }
    final metadata = _metadata;
    final store = _snapshotStore;
    if (metadata != null && store != null) {
      final totalMilliseconds = currentDuration?.inMilliseconds ?? 0;
      final position = player.positionSeconds;
      unawaited(
        store.save(
          WidgetPlaybackSnapshot(
            bookId: metadata.bookId,
            title: metadata.bookTitle,
            chapter: metadata.chapterTitle,
            position: position,
            duration: totalMilliseconds / 1000,
            isPlaying: player.isPlaying,
            progress: totalMilliseconds > 0
                ? (position * 1000 / totalMilliseconds).clamp(0.0, 1.0)
                : 0,
          ),
        ),
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}
