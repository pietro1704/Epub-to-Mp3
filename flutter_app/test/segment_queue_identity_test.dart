import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_app/services/audio_player_service.dart';

class RecordingPlaylistPlayer extends AudioPlayer {
  RecordingPlaylistPlayer()
    : super(handleInterruptions: false, handleAudioSessionActivation: false);
  final playlists = <List<Uri>>[];
  bool rejectNext = false;

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    if (rejectNext) {
      rejectNext = false;
      throw StateError('Decoder rejected fixture');
    }
    playlists.add(
      sources.cast<UriAudioSource>().map((source) => source.uri).toList(),
    );
    return null;
  }

  @override
  Future<void> addAudioSource(AudioSource source) async {
    playlists.last.add((source as UriAudioSource).uri);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'chapter replacement retires queued segments and preserves new segment order',
    () async {
      final native = RecordingPlaylistPlayer();
      final player = AudioPlayerService(player: native);
      addTearDown(player.dispose);
      player.enqueueSegment(Uri.file('/retired/one.wav'), chapterIndex: 1);
      player.enqueueSegment(Uri.file('/retired/two.wav'), chapterIndex: 1);
      player.enqueueSegment(Uri.file('/current/one.wav'), chapterIndex: 2);
      player.enqueueSegment(Uri.file('/current/two.wav'), chapterIndex: 2);
      await Future<void>.delayed(Duration.zero);
      expect(native.playlists, [
        [Uri.file('/current/one.wav'), Uri.file('/current/two.wav')],
      ]);
    },
  );

  test(
    'clearing segments cancels pending work and permits the same chapter again',
    () async {
      final native = RecordingPlaylistPlayer();
      final player = AudioPlayerService(player: native);
      addTearDown(player.dispose);
      player.enqueueSegment(Uri.file('/cancelled.wav'), chapterIndex: 4);
      player.clearSegmentState();
      await Future<void>.delayed(Duration.zero);
      expect(native.playlists, isEmpty);
      player.enqueueSegment(Uri.file('/retry.wav'), chapterIndex: 4);
      await Future<void>.delayed(Duration.zero);
      expect(native.playlists, [
        [Uri.file('/retry.wav')],
      ]);
    },
  );

  test(
    'segment decoder failure publishes failure without an unhandled async error',
    () async {
      final native = RecordingPlaylistPlayer()..rejectNext = true;
      final player = AudioPlayerService(player: native);
      addTearDown(player.dispose);
      player.enqueueSegment(Uri.file('/unreadable.wav'), chapterIndex: 4);
      await Future<void>.delayed(Duration.zero);
      expect(player.phase, PlaybackPhase.failed);
      expect(player.isPlaying, isFalse);
    },
  );
}
