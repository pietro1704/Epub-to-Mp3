import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/app_settings.dart' show RemoteButtonMode;
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
  BackgroundAudioHandler(this.player, {this._snapshotStore}) {
    _changes = player.stateChanges.listen((_) => _publishState());
    _publishState();
  }

  final AudioPlayerInterface player;
  final WidgetPlaybackSnapshotStore? _snapshotStore;
  late final StreamSubscription<void> _changes;
  bool _disposed = false;
  String? _lastMetadataId;
  BackgroundAudioMetadata? _metadata;

  RemoteButtonMode _remoteButtonMode = RemoteButtonMode.chapter;

  /// What the external next/previous buttons do; the published controls follow it.
  RemoteButtonMode get remoteButtonMode => _remoteButtonMode;
  set remoteButtonMode(RemoteButtonMode mode) {
    if (_remoteButtonMode == mode) return;
    _remoteButtonMode = mode;
    _publishState();
  }

  Future<void> setMetadata(BackgroundAudioMetadata metadata) async {
    _metadata = metadata;
    final item = BackgroundAudioMetadataMapper.toMediaItem(metadata);
    if (_lastMetadataId == item.id && mediaItem.value == item) return;
    _lastMetadataId = item.id;
    mediaItem.add(item);
    _publishState(duration: metadata.duration);
  }

  /// Starts the narration of the current book when nothing is queued yet, like the mini
  /// player's Play. Remote Play (car, headphones, lock screen, MPRIS) otherwise has nothing to
  /// resume and would be ignored.
  Future<void> Function()? startNarration;

  /// A seek or skip that came from outside the app (lock screen, headphones, car, MPRIS): explicit
  /// playback navigation, so the reader follows the narration again.
  void Function()? onRemoteJump;

  @override
  Future<void> play() async {
    final start = startNarration;
    // Starting the narration takes a whole synthesis and the player's play() completes only when
    // playback stops: a remote command (MPRIS reply, MediaSession) must not wait for either.
    // State changes republish on their own.
    final started = !player.hasQueuedAudio && start != null
        ? start()
        : player.play();
    unawaited(
      started.catchError((Object error) {
        debugPrint('Remote play failed: $error');
      }),
    );
    _publishState();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    _publishState();
  }

  @override
  Future<void> seek(Duration position) async {
    onRemoteJump?.call();
    await player.seek(position);
    _publishState();
  }

  @override
  Future<void> fastForward() async {
    onRemoteJump?.call();
    player.skipForward();
    _publishState();
  }

  @override
  Future<void> rewind() async {
    onRemoteJump?.call();
    player.skipBackward();
    _publishState();
  }

  @override
  Future<void> skipToNext() async {
    onRemoteJump?.call();
    // Head units that only know track commands still get the user's choice (REMOTE-BUTTON-MODE).
    if (_remoteButtonMode == RemoteButtonMode.seconds) {
      player.skipForward();
    } else {
      player.nextChapter();
    }
    _publishState();
  }

  @override
  Future<void> skipToPrevious() async {
    onRemoteJump?.call();
    if (_remoteButtonMode == RemoteButtonMode.seconds) {
      player.skipBackward();
    } else {
      player.previousChapter();
    }
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
        if (_remoteButtonMode == RemoteButtonMode.seconds)
          MediaControl.rewind
        else
          MediaControl.skipToPrevious,
        player.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        if (_remoteButtonMode == RemoteButtonMode.seconds)
          MediaControl.fastForward
        else
          MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: switch (player.phase) {
        PlaybackPhase.loading => AudioProcessingState.loading,
        PlaybackPhase.buffering => AudioProcessingState.buffering,
        PlaybackPhase.completed => AudioProcessingState.completed,
        PlaybackPhase.failed => AudioProcessingState.error,
        PlaybackPhase.playing ||
        PlaybackPhase.paused => AudioProcessingState.ready,
        PlaybackPhase.idle => AudioProcessingState.idle,
      },
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
    await _changes.cancel();
    await player.dispose();
  }
}
