import 'dart:async';

import 'audio_player_service.dart';

const _unchangedIdentity = Object();

/// Immutable state published by the playback coordinator.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.revision,
    required this.isPlaying,
    required this.isLoading,
    required this.position,
    required this.duration,
    required this.playerIndex,
    required this.chapterIndex,
    required this.speed,
    this.phase = PlaybackPhase.idle,
  });

  const PlaybackSnapshot.initial()
    : revision = 0,
      isPlaying = false,
      isLoading = false,
      position = Duration.zero,
      duration = Duration.zero,
      playerIndex = null,
      chapterIndex = null,
      speed = 1.0,
      phase = PlaybackPhase.idle;

  final PlaybackPhase phase;
  final int revision;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration duration;
  final int? playerIndex;
  final int? chapterIndex;
  final double speed;

  PlaybackSnapshot copyWith({
    PlaybackPhase? phase,
    bool? isPlaying,
    bool? isLoading,
    Duration? position,
    Duration? duration,
    Object? playerIndex = _unchangedIdentity,
    Object? chapterIndex = _unchangedIdentity,
    double? speed,
  }) {
    return PlaybackSnapshot(
      phase: phase ?? this.phase,
      revision: revision + 1,
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playerIndex: identical(playerIndex, _unchangedIdentity) ? this.playerIndex : playerIndex as int?,
      chapterIndex: identical(chapterIndex, _unchangedIdentity) ? this.chapterIndex : chapterIndex as int?,
      speed: speed ?? this.speed,
    );
  }
}

/// Single source of truth for playback UI and system integrations.
class PlaybackCoordinator {
  PlaybackCoordinator(this.player) {
    _subscriptions.add(player.phases.listen((_) => _publish()));
    _subscriptions.add(player.position.listen((_) => _publish()));
    _subscriptions.add(player.currentIndex.listen((_) => _publish()));
    _publish();
  }

  final AudioPlayerInterface player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _controller = StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.initial();
  bool _disposed = false;
  bool _initialAudioPending = false;

  PlaybackSnapshot get snapshot => _snapshot;
  Stream<PlaybackSnapshot> get stream => _controller.stream;

  void beginInitialAudioRequest() {
    if (player.isPlaying || player.hasQueuedAudio || _initialAudioPending) {
      return;
    }
    _initialAudioPending = true;
    _publish();
  }

  void firstAudioReady() {
    if (!_initialAudioPending) return;
    _initialAudioPending = false;
    _publish();
  }

  void finishInitialAudioRequest() {
    if (!_initialAudioPending) return;
    _initialAudioPending = false;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    final playerIndex = player.currentIndexValue;
    final next = PlaybackSnapshot(
      revision: _snapshot.revision + 1,
      isPlaying: player.isPlaying,
      phase: _initialAudioPending ? PlaybackPhase.loading : player.phase,
      isLoading: _initialAudioPending || player.isLoading,
      position: Duration(milliseconds: (player.positionSeconds * 1000).round()),
      duration: Duration(milliseconds: (player.durationSeconds * 1000).round()),
      playerIndex: playerIndex,
      chapterIndex: playerIndex == null
          ? null
          : player.chapterIndexForPlayerIndex(playerIndex),
      speed: player.speed,
    );
    _snapshot = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _controller.close();
  }
}
