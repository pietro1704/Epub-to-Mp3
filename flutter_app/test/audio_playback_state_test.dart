import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_app/services/audio_playback_state.dart';
import 'package:flutter_app/services/audio_player_interface.dart';
import 'package:flutter_app/services/fake_audio_player_service.dart';
import 'package:flutter_app/services/playback_snapshot.dart';

class DecoderStatePlayer extends FakeAudioPlayerService {
  final changes = StreamController<PlaybackPhase>.broadcast();
  PlaybackPhase decoderPhase = PlaybackPhase.idle;
  @override PlaybackPhase get phase => decoderPhase;
  @override Stream<PlaybackPhase> get phases => changes.stream;
  @override bool get isPlaying => phase == PlaybackPhase.playing;
  @override bool get isLoading => phase == PlaybackPhase.loading || phase == PlaybackPhase.buffering;
  void emit(PlaybackPhase phase) { decoderPhase = phase; changes.add(phase); }
  @override Future<void> dispose() async { await changes.close(); await super.dispose(); }
}

void main() {
  test('raw play intent cannot advertise completion, buffering or idle as playing', () {
    for (final intent in [true, false]) {
      expect(AudioPlaybackState.resolve(PlayerState(intent, ProcessingState.completed)), PlaybackPhase.completed);
      expect(AudioPlaybackState.resolve(PlayerState(intent, ProcessingState.idle)), PlaybackPhase.idle);
      expect(AudioPlaybackState.resolve(PlayerState(intent, ProcessingState.buffering)), PlaybackPhase.buffering);
    }
    expect(AudioPlaybackState.resolve(PlayerState(true, ProcessingState.ready)), PlaybackPhase.playing);
    expect(AudioPlaybackState.resolve(PlayerState(false, ProcessingState.ready)), PlaybackPhase.paused);
  });

  test('coordinator publishes decoder-only loading, failure, retry and completion transitions', () async {
    final player = DecoderStatePlayer();
    final coordinator = PlaybackCoordinator(player);
    addTearDown(player.dispose);
    addTearDown(coordinator.dispose);
    for (final phase in [PlaybackPhase.loading, PlaybackPhase.playing, PlaybackPhase.buffering,
        PlaybackPhase.playing, PlaybackPhase.paused, PlaybackPhase.failed, PlaybackPhase.loading,
        PlaybackPhase.playing, PlaybackPhase.completed, PlaybackPhase.idle]) {
      final previous = coordinator.snapshot.revision;
      player.emit(phase);
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.phase, phase);
      expect(coordinator.snapshot.isPlaying, phase == PlaybackPhase.playing);
      expect(coordinator.snapshot.isLoading, phase == PlaybackPhase.loading || phase == PlaybackPhase.buffering);
      expect(coordinator.snapshot.revision, greaterThan(previous));
    }
  });
}
