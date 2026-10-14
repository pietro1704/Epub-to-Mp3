import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/reader_playback_startup.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/models/job_snapshot.dart';

void main() {
  test(
    'opening cached audio alone never starts playback; explicit Listen does',
    () async {
      final startup = ReaderPlaybackStartup();
      final player = FakeAudioPlayerService();
      await player.setQueue([
        ChapterProgress(index: 4, name: 'Cached4', status: 'completed'),
      ]);
      Future<void> start(int index) async {
        await player.seek(Duration.zero, index: index);
        await player.play();
      }

      await startup.startWhenReady(1, [4], start);
      expect(player.isPlaying, false);
      startup.request(1, 4);
      await startup.startWhenReady(1, [4], start);
      expect(player.isPlaying, true);
      await player.dispose();
    },
  );

  test(
    'requested missing chapter starts when ready despite other cached chapters',
    () async {
      final startup = ReaderPlaybackStartup()..request(3, 7);
      final starts = <int>[];
      await startup.startWhenReady(3, [2, 4], (index) async {
        starts.add(index);
      });
      expect(starts, isEmpty);
      await startup.startWhenReady(3, [2, 4, 7], (index) async {
        starts.add(index);
      });
      await startup.startWhenReady(3, [2, 4, 7, 8], (index) async {
        starts.add(index);
      });
      expect(starts, [2]);
    },
  );

  test(
    'book switch invalidates deferred resume and late old generation callbacks',
    () async {
      final startup = ReaderPlaybackStartup()..request(1, 7);
      final resume = Completer<void>();
      var oldPlayed = false;
      final old = startup.startWhenReady(1, [7], (_) async {
        await resume.future;
        if (startup.accepts(1)) oldPlayed = true;
      });
      startup.invalidate();
      startup.request(2, 3);
      var newStarts = 0;
      await startup.startWhenReady(1, [7], (_) async {
        oldPlayed = true;
      });
      await startup.startWhenReady(2, [3], (_) async {
        newStarts++;
      });
      resume.complete();
      await old;
      expect(oldPlayed, false);
      expect(newStarts, 1);
    },
  );
}
