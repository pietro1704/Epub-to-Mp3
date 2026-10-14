import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/growing_chapter_audio_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'final chapter publication preserves its live source and playlist',
    () async {
      final native = AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      final player = AudioPlayerService(player: native);
      final source = GrowingChapterAudioSource('/request-4');
      player.registerGrowingChapter(4, source);
      await player.setQueue([
        ChapterProgress(
          index: 4,
          name: 'Chapter4',
          status: 'running',
          downloadUrl: Uri(
            scheme: 'growing',
            path: source.requestId,
          ).toString(),
        ),
      ]);
      final playlist = native.audioSource;
      expect(native.sequence!.single, same(source));
      source.complete();
      player.finishGrowingChapter(4, '/final/chapter4.mp3');
      await player.setQueue([
        ChapterProgress(
          index: 4,
          name: 'Chapter4',
          status: 'completed',
          downloadUrl: Uri.file('/final/chapter4.mp3').toString(),
        ),
      ]);
      expect(native.audioSource, same(playlist));
      expect(native.sequence!.single, same(source));
      expect(player.chapters.single.index, 4);
      expect(player.chapters.single.status, 'completed');
      await player.dispose();
    },
  );
}
