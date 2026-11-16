import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/playback_snapshot.dart';
import 'package:flutter_app/services/fake_audio_player_service.dart';
import 'package:flutter_app/models/job_snapshot.dart';

void main() {
  test('explicit book selection clears old audio and preserves an existing session', () async {
    final player = FakeAudioPlayerService()..currentBookId = 'first';
    await player.setQueue([
      const ChapterProgress(index: 0, name: 'First', status: 'completed'),
    ]);
    await player.play();
    final coordinator = PlaybackCoordinator(player);
    expect(await coordinator.selectBook('first'), true);
    expect(player.isPlaying, true);
    expect(player.chapters, isNotEmpty);
    expect(await coordinator.selectBook('second'), true);
    expect(player.currentBookId, 'second');
    expect(player.chapters, isEmpty);
    expect(player.isPlaying, false);
    await coordinator.dispose();
    await player.dispose();
  });
}
