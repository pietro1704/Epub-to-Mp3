import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'audio_player_interface.dart';

/// Translates confirmed decoder state and errors for every playback surface.
class AudioPlaybackState {
  AudioPlaybackState(AudioPlayer player) {
    _phase = resolve(player.playerState);
    _state = player.playerStateStream.listen((state) {
      if (!_failed) _publish(resolve(state));
    });
    _events = player.playbackEventStream.listen((_) {}, onError: (Object error) {
      _failed = true;
      _publish(PlaybackPhase.failed);
    });
  }
  final _changes = StreamController<PlaybackPhase>.broadcast();
  late final StreamSubscription<PlayerState> _state;
  late final StreamSubscription<PlaybackEvent> _events;
  late PlaybackPhase _phase;
  bool _failed = false;
  PlaybackPhase get phase => _phase;
  Stream<PlaybackPhase> get changes => _changes.stream;
  void beginRequest(PlayerState state) {
    _failed = false;
    _publish(resolve(state));
  }
  void fail() {
    _failed = true;
    _publish(PlaybackPhase.failed);
  }
  void _publish(PlaybackPhase phase) {
    _phase = phase;
    _changes.add(phase);
  }
  static PlaybackPhase resolve(PlayerState state) => switch (state.processingState) {
    ProcessingState.idle => PlaybackPhase.idle,
    ProcessingState.loading => PlaybackPhase.loading,
    ProcessingState.buffering => PlaybackPhase.buffering,
    ProcessingState.completed => PlaybackPhase.completed,
    ProcessingState.ready => state.playing ? PlaybackPhase.playing : PlaybackPhase.paused,
  };
  Future<void> dispose() async {
    await _state.cancel();
    await _events.cancel();
    await _changes.close();
  }
}
