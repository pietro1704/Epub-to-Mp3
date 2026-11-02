import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_app/services/audio_playback_state.dart';
import 'package:flutter_app/services/audio_player_interface.dart';
import 'package:flutter_app/services/fake_audio_player_service.dart';
import 'package:flutter_app/services/playback_snapshot.dart';
import 'package:flutter_app/services/background_audio_handler.dart';
import 'package:flutter_app/views/full_player_sheet.dart';

class DecoderEventPlayer implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast();
  final events = StreamController<PlayerException>.broadcast();
  @override
  PlayerState get playerState => PlayerState(false, ProcessingState.idle);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<PlayerException> get errorStream => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DecoderStatePlayer extends FakeAudioPlayerService {
  final changes = StreamController<PlaybackPhase>.broadcast();
  PlaybackPhase decoderPhase = PlaybackPhase.idle;
  int pauseRequests = 0;
  @override
  Future<void> pause() async {
    pauseRequests++;
  }

  @override
  void togglePlayPause() {
    if (isPlaying || isLoading) {
      pause();
    } else {
      play();
    }
  }

  @override
  PlaybackPhase get phase => decoderPhase;
  @override
  Stream<PlaybackPhase> get phases => changes.stream;
  @override
  bool get isPlaying => phase == PlaybackPhase.playing;
  @override
  bool get isLoading =>
      phase == PlaybackPhase.loading || phase == PlaybackPhase.buffering;
  void emit(PlaybackPhase phase) {
    decoderPhase = phase;
    changes.add(phase);
  }

  @override
  Future<void> dispose() async {
    await changes.close();
    await super.dispose();
  }
}

void main() {
  test(
    'decode failure survives later state events until an explicit retry',
    () async {
      final decoder = DecoderEventPlayer();
      final state = AudioPlaybackState(decoder);
      decoder.events.add(PlayerException(1, 'Unreadable fixture', null));
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, PlaybackPhase.failed);
      decoder.states.add(PlayerState(true, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, PlaybackPhase.failed);
      state.beginRequest(PlayerState(false, ProcessingState.loading));
      expect(state.phase, PlaybackPhase.loading);
      decoder.states.add(PlayerState(false, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, PlaybackPhase.paused);
      await state.dispose();
      decoder.states.add(PlayerState(true, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, PlaybackPhase.paused);
      await decoder.states.close();
      await decoder.events.close();
    },
  );

  test(
    'system player receives loading, buffering, failure and completion',
    () async {
      final player = DecoderStatePlayer();
      final handler = BackgroundAudioHandler(player);
      addTearDown(player.dispose);
      addTearDown(handler.dispose);
      for (final entry in {
        PlaybackPhase.loading: AudioProcessingState.loading,
        PlaybackPhase.buffering: AudioProcessingState.buffering,
        PlaybackPhase.failed: AudioProcessingState.error,
        PlaybackPhase.completed: AudioProcessingState.completed,
        PlaybackPhase.paused: AudioProcessingState.ready,
      }.entries) {
        player.emit(entry.key);
        await Future<void>.delayed(Duration.zero);
        expect(handler.playbackState.value.processingState, entry.value);
        expect(handler.playbackState.value.playing, isFalse);
      }
    },
  );

  testWidgets(
    'transport can pause loading and shows play after decoder completion',
    (tester) async {
      final player = DecoderStatePlayer();
      addTearDown(player.dispose);
      player.emit(PlaybackPhase.loading);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlayerTransportControls(player: player)),
        ),
      );
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause_circle_filled));
      expect(player.pauseRequests, 1);
      player.emit(PlaybackPhase.completed);
      await tester.pump();
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      expect(find.byIcon(Icons.pause_circle_filled), findsNothing);
    },
  );
  test(
    'raw play intent cannot advertise completion, buffering or idle as playing',
    () {
      for (final intent in [true, false]) {
        expect(
          AudioPlaybackState.resolve(
            PlayerState(intent, ProcessingState.completed),
          ),
          PlaybackPhase.completed,
        );
        expect(
          AudioPlaybackState.resolve(PlayerState(intent, ProcessingState.idle)),
          PlaybackPhase.idle,
        );
        expect(
          AudioPlaybackState.resolve(
            PlayerState(intent, ProcessingState.buffering),
          ),
          PlaybackPhase.buffering,
        );
      }
      expect(
        AudioPlaybackState.resolve(PlayerState(true, ProcessingState.ready)),
        PlaybackPhase.playing,
      );
      expect(
        AudioPlaybackState.resolve(PlayerState(false, ProcessingState.ready)),
        PlaybackPhase.paused,
      );
    },
  );

  test(
    'coordinator publishes decoder-only loading, failure, retry and completion transitions',
    () async {
      final player = DecoderStatePlayer();
      final coordinator = PlaybackCoordinator(player);
      addTearDown(player.dispose);
      addTearDown(coordinator.dispose);
      for (final phase in [
        PlaybackPhase.loading,
        PlaybackPhase.playing,
        PlaybackPhase.buffering,
        PlaybackPhase.playing,
        PlaybackPhase.paused,
        PlaybackPhase.failed,
        PlaybackPhase.loading,
        PlaybackPhase.playing,
        PlaybackPhase.completed,
        PlaybackPhase.idle,
      ]) {
        final previous = coordinator.snapshot.revision;
        player.emit(phase);
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.snapshot.phase, phase);
        expect(coordinator.snapshot.isPlaying, phase == PlaybackPhase.playing);
        expect(
          coordinator.snapshot.isLoading,
          phase == PlaybackPhase.loading || phase == PlaybackPhase.buffering,
        );
        expect(coordinator.snapshot.revision, greaterThan(previous));
      }
    },
  );
}
