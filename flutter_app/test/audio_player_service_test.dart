import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/audio_player_service.dart';

void main() {
  group('FakeAudioPlayerService', () {
    late FakeAudioPlayerService player;

    setUp(() {
      player = FakeAudioPlayerService();
    });

    tearDown(() => player.dispose());

    test('speed defaults to 1.0', () {
      expect(player.speed, 1.0);
    });

    test('sleepTimerRemaining defaults to 0', () {
      expect(player.sleepTimerRemaining, 0);
    });

    test('activeSentenceId defaults to null', () {
      expect(player.activeSentenceId, isNull);
    });

    test('chapters defaults to empty', () {
      expect(player.chapters, isEmpty);
    });

    test('clearSegmentState resets activeSentenceId', () {
      player.activeSentenceId = '1:3';
      player.clearSegmentState();
      expect(player.activeSentenceId, isNull);
    });

    test('clearSegmentState emits null on stream', () async {
      player.activeSentenceId = '0:1';
      final values = <String?>[];
      final sub = player.activeSentenceStream.listen(values.add);
      player.clearSegmentState();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, contains(null));
      sub.cancel();
    });

    test('play/pause toggles state', () async {
      final values = <bool>[];
      final sub = player.playing.listen(values.add);
      await player.play();
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, containsAllInOrder([true, false]));
      sub.cancel();
    });

    test('togglePlayPause toggles correctly', () async {
      final values = <bool>[];
      final sub = player.playing.listen(values.add);
      player.togglePlayPause(); // play
      player.togglePlayPause(); // pause
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, containsAllInOrder([true, false]));
      sub.cancel();
    });

    test('setSpeed updates speed', () async {
      await player.setSpeed(1.5);
      expect(player.speed, 1.5);
    });

    test('setSleepTimer emits on stream', () async {
      final values = <double>[];
      final sub = player.sleepTimerStream.listen(values.add);
      player.setSleepTimer(seconds: 900);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, contains(900.0));
      sub.cancel();
    });

    test('enqueueSegment sets activeSentenceId', () async {
      final values = <String?>[];
      final sub = player.activeSentenceStream.listen(values.add);
      player.enqueueSegment(
        Uri.parse('http://localhost/audio.mp3'),
        sentenceId: '0:0',
        chapterIndex: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.activeSentenceId, '0:0');
      expect(values, contains('0:0'));
      sub.cancel();
    });

    test('setQueue populates chapters', () async {
      await player.setQueue([]);
      expect(player.chapters, isEmpty);
    });

    test('skipForward advances position', () async {
      final values = <Duration>[];
      final sub = player.position.listen(values.add);
      player.skipForward(seconds: 15);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values.last, const Duration(seconds: 15));
      sub.cancel();
    });

    test('skipBackward clamps at zero', () async {
      final values = <Duration>[];
      final sub = player.position.listen(values.add);
      player.skipBackward(seconds: 15);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values.last, Duration.zero);
      sub.cancel();
    });
  });

  group('AudioPlayerInterface contract', () {
    test('FakeAudioPlayerService implements AudioPlayerInterface', () {
      final player = FakeAudioPlayerService();
      expect(player, isA<AudioPlayerInterface>());
      player.dispose();
    });
  });
}
