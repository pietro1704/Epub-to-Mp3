import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/background_audio_handler.dart';
import 'package:flutter_app/services/playback_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_audio_player_service.dart';

const _chapters = [
  ChapterProgress(index: 0, name: 'One', status: 'done'),
  ChapterProgress(index: 1, name: 'Two', status: 'done'),
];

void main() {
  test('stateChanges emits for phase, position and index changes', () async {
    final player = FakeAudioPlayerService();
    var changes = 0;
    final subscription = player.stateChanges.listen((_) => changes++);

    await player.play();
    await player.seek(const Duration(seconds: 3));
    await player.setQueue(_chapters);
    await Future<void>.delayed(Duration.zero);

    expect(changes, 3);

    await subscription.cancel();
    await player.pause();
    player.skipForward();
    player.nextChapter();
    await Future<void>.delayed(Duration.zero);

    expect(changes, 3, reason: 'cancelling must detach every source');
    await player.dispose();
  });

  test('each listener receives its own change stream', () async {
    final player = FakeAudioPlayerService();
    var first = 0;
    var second = 0;
    final a = player.stateChanges.listen((_) => first++);
    final b = player.stateChanges.listen((_) => second++);

    player.skipForward();
    await Future<void>.delayed(Duration.zero);
    await a.cancel();
    player.skipForward();
    await Future<void>.delayed(Duration.zero);

    expect(first, 1);
    expect(second, 2);
    await b.cancel();
    await player.dispose();
  });

  test('coordinator and media session follow player changes', () async {
    final player = FakeAudioPlayerService();
    final coordinator = PlaybackCoordinator(player);
    final handler = BackgroundAudioHandler(player);
    await player.setQueue(_chapters);

    await player.seek(const Duration(seconds: 9), index: 1);
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.snapshot.position, const Duration(seconds: 9));
    expect(coordinator.snapshot.playerIndex, 1);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 9),
    );
    expect(handler.playbackState.value.queueIndex, 1);

    await player.play();
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.snapshot.isPlaying, isTrue);
    expect(handler.playbackState.value.playing, isTrue);

    await coordinator.dispose();
    await handler.dispose();
  });
}
