import 'dart:async';
import 'dart:typed_data';

import '../../models/job_snapshot.dart';
import 'growing_chapter_audio_source.dart';

abstract interface class StreamingChapterPlayer {
  void registerGrowingChapter(
    int chapterIndex,
    GrowingChapterAudioSource source,
  );
  void finishGrowingChapter(int chapterIndex, String finalPath);
}

enum PlaybackPhase {
  idle,
  loading,
  buffering,
  playing,
  paused,
  completed,
  failed,
}

abstract class AudioPlayerInterface {
  /// Identity of the exact audible media item, not a chapter-wide guess.
  Uri? get currentAudioUri => null;
  String? currentBookId;
  int seekForwardSeconds = 15;
  int seekBackwardSeconds = 15;
  List<int> sourceChapterIndices = const [];
  /// Adds the requested source chapter to the playback queue when available.
  Future<bool> Function(int sourceChapter)? onPrepareSourceChapter;

  /// A skip landed outside the audio that exists (the playing chapter is still
  /// being synthesized, so it cannot be sought). The owner restarts synthesis at
  /// the estimated text position of [target] (media time in that chapter's audio)
  /// and returns true; false lets the skip continue into the next chapter.
  Future<bool> Function(int sourceChapter, Duration target)?
  onSkipOutsideCache;
  PlaybackPhase get phase => isLoading
      ? PlaybackPhase.loading
      : isPlaying
      ? PlaybackPhase.playing
      : hasQueuedAudio
      ? PlaybackPhase.paused
      : PlaybackPhase.idle;
  Stream<PlaybackPhase> get phases => playing.map((_) => phase);

  /// Emits whenever an observable playback value changes: phase, position or
  /// queue index. Playback observers subscribe here instead of wiring those
  /// source streams themselves, so the change definition has one owner.
  Stream<void> get stateChanges {
    final subscriptions = <StreamSubscription<dynamic>>[];
    late final StreamController<void> controller;
    controller = StreamController<void>(
      sync: true,
      onListen: () {
        final sources = <Stream<dynamic>>[phases, position, currentIndex];
        for (final source in sources) {
          subscriptions.add(
            source.listen(
              (_) => controller.add(null),
              onError: controller.addError,
            ),
          );
        }
      },
      onCancel: () async {
        final active = List.of(subscriptions);
        subscriptions.clear();
        for (final subscription in active) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  Stream<Duration> get position;
  Stream<bool> get playing;
  bool get isPlaying;
  bool get isLoading;
  Stream<int?> get currentIndex;
  int? get currentIndexValue;
  String? get activeSentenceId;
  Stream<String?> get activeSentenceStream;
  double get speed;
  double get sleepTimerRemaining;
  Stream<double> get sleepTimerStream;
  double get positionSeconds;
  double get durationSeconds;
  Uint8List? get coverArtData;
  set coverArtData(Uint8List? value);
  List<ChapterProgress> get chapters;
  bool get hasQueuedAudio;
  int chapterIndexForPlayerIndex(int playerIndex);

  Future<void> setQueue(List<ChapterProgress> chapters);
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> setSpeed(double speed);
  void skipForward({int? seconds});
  void skipBackward({int? seconds});
  void nextChapter();
  void previousChapter();
  void togglePlayPause();
  void setSleepTimer({required double seconds});
  void clearSegmentState();
  Future<void> dispose();
}
