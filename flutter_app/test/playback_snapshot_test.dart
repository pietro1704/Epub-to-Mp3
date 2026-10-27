import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/playback_snapshot.dart';

void main() {
  test('explicitly clears retired identity without changing omitted fields', () {
    final initial = const PlaybackSnapshot.initial().copyWith(playerIndex: 2, chapterIndex: 16);
    expect(initial.copyWith(isPlaying: false).chapterIndex, 16);
    final retired = initial.copyWith(playerIndex: null, chapterIndex: null);
    expect(retired.playerIndex, isNull);
    expect(retired.chapterIndex, isNull);
    expect(retired.revision, initial.revision + 1);
  });
  test(
    'publishes one immutable snapshot for playing and chapter changes',
    () async {
      final player = FakeAudioPlayerService();
      await player.setQueue([
        const ChapterProgress(index: 0, name: 'Chapter 1'),
        const ChapterProgress(index: 1, name: 'Chapter 2'),
      ]);
      final coordinator = PlaybackCoordinator(player);
      addTearDown(coordinator.dispose);

      await player.play();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.isPlaying, isTrue);
      final playingRevision = coordinator.snapshot.revision;

      player.nextChapter();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.chapterIndex, 1);
      expect(coordinator.snapshot.revision, greaterThan(playingRevision));
    },
  );

  test('does not expose mutable player state as the UI contract', () {
    final player = FakeAudioPlayerService();
    final coordinator = PlaybackCoordinator(player);
    addTearDown(coordinator.dispose);

    expect(coordinator.snapshot, isA<PlaybackSnapshot>());
    expect(coordinator.snapshot.revision, greaterThanOrEqualTo(1));
  });

  test(
    'spinner ends when first requested audio is ready, not on later conversion',
    () async {
      final player = FakeAudioPlayerService();
      final coordinator = PlaybackCoordinator(player);
      addTearDown(coordinator.dispose);

      coordinator.beginInitialAudioRequest();
      expect(coordinator.snapshot.isLoading, isTrue);

      await player.setQueue([
        const ChapterProgress(index: 0, name: 'Chapter 1'),
      ]);
      await player.play();
      coordinator.firstAudioReady();
      expect(coordinator.snapshot.isPlaying, isTrue);
      expect(coordinator.snapshot.isLoading, isFalse);

      coordinator.beginInitialAudioRequest();
      expect(coordinator.snapshot.isLoading, isFalse);
    },
  );
}
