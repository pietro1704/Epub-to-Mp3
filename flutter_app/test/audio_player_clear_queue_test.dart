import 'package:flutter_app/services/playback/audio_player_service.dart';
import 'package:flutter_app/services/playback/playback_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty queue clears the player without failing', () async {
    final service = AudioPlayerService(player: AudioPlayer());
    addTearDown(service.dispose);
    final phases = <PlaybackPhase>[];
    final subscription = service.phases.listen(phases.add);
    addTearDown(subscription.cancel);

    await service.setQueue(const []);

    expect(service.hasQueuedAudio, isFalse);
    expect(service.chapters, isEmpty);
    expect(phases, isNot(contains(PlaybackPhase.failed)));
  });

  test('switching to a book with no audio yet leaves the new book selectable (mini player Play)', () async {
    final service = AudioPlayerService(player: AudioPlayer());
    addTearDown(service.dispose);
    final coordinator = PlaybackCoordinator(service);
    addTearDown(coordinator.dispose);
    service.currentBookId = 'old';

    expect(await coordinator.selectBook('new'), isTrue);

    expect(service.currentBookId, 'new');
    expect(service.phase, isNot(PlaybackPhase.failed));
  });
}
